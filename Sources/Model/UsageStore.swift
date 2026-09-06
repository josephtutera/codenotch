import AppKit
import Combine
import os

/// Fetches every provider on a timer and keeps the last good answer around, so
/// a dropped network shows yesterday's number dimmed rather than a blank ring.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    /// Providers with a fetch in flight, so the cell can show it happening.
    @Published private(set) var refreshing: Set<String> = []

    /// Replaced wholesale when accounts are added or removed — see
    /// `replaceProviders`.
    private(set) var providers: [UsageProvider]
    /// Providers the user has switched off. They are not fetched at all — their
    /// credential is never read, which is the whole point of switching one off.
    /// Filtering the results afterwards would still touch the keychain.
    @Published var disconnected: Set<String> = [] {
        didSet {
            guard disconnected != oldValue else { return }
            snapshots.removeAll { disconnected.contains($0.id) }
            // The remembered reading has to go as well. Dropping it from
            // `snapshots` alone left it in `lastGood`, which is written to the
            // archive wholesale on every fetch — so a switched-off provider was
            // remembered forever and rebuilt from the archive at the next
            // launch, ring and all.
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
            refreshNow()
        }
    }

    /// How often to look. The floor is not politeness: every tick is an HTTPS
    /// call per Claude account against an endpoint that answers 429 and then
    /// backs off for minutes, plus a spawned `codex app-server` per Codex
    /// account. Half a minute is as fast as that is worth paying for.
    private let refreshInterval: TimeInterval
    /// How long a snapshot stays believable after its last successful fetch.
    private let staleAfter: TimeInterval
    /// When the last fetch was *started*, which is what the unfold cooldown is
    /// measured from. Started, not finished: a request in flight is already
    /// buying the freshness a second one would ask for.
    private var lastAttempt: Date?

    private let archive: UsageArchive
    private var lastGood: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// Set synchronously before the task exists, so "is one already running"
    /// never depends on when the task body happens to start.
    private var isRefreshing = false
    private var wakeObserver: NSObjectProtocol?

    init(
        providers: [UsageProvider],
        refreshInterval: TimeInterval = 30,
        staleAfter: TimeInterval = 5 * 60,
        archive: UsageArchive = UsageArchive(),
        disconnected: Set<String> = []
    ) {
        self.providers = providers
        self.refreshInterval = refreshInterval
        self.staleAfter = staleAfter
        self.archive = archive

        // Open on what we knew last time rather than on an empty ring; the
        // first fetch will either confirm it or replace it.
        // Set through the wrapper's storage, not `self.disconnected = …`.
        // `disconnected` is `@Published`, so a plain assignment here runs its
        // `didSet` — which saves `lastGood` to the archive. At this point
        // `lastGood` is still empty, so it wrote an empty archive and destroyed
        // every remembered reading on any launch with a provider switched off.
        _disconnected = Published(initialValue: disconnected)
        lastGood = archive.load()
        // Pruned here as well as in `didSet`, because `didSet` cannot be relied
        // on to run: it guards against a no-op change, and the value the
        // preference binding delivers a moment later is usually identical to
        // the one passed in here. A provider switched off in a previous session
        // would then keep its archived reading indefinitely.
        if lastGood.keys.contains(where: disconnected.contains) {
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
        }
        // Filtered here, not only in `didSet`. The store is built before the
        // preference reaches it, so an unfiltered first pass draws every
        // switched-off provider for as long as it takes the binding to arrive.
        snapshots = providers.filter { !disconnected.contains($0.id) }.map { provider in
            guard let remembered = lastGood[provider.id] else { return Self.placeholder(provider) }
            var snapshot = remembered.snapshot
            snapshot.status = .stale(since: remembered.fetchedAt)
            return snapshot
        }
    }

    /// Swap the provider list for another, keeping what is known about the
    /// providers that survive.
    ///
    /// Adding, renaming or removing an account in settings lands here. The
    /// store is built once at launch, and rebuilding it — bindings, timer,
    /// wake observer and all — for a rename would be a restart by another
    /// name. A removed provider's remembered reading goes with it, for the
    /// reason `signOut` gives: nothing should bring numbers back for an
    /// account that was deliberately taken off the notch.
    func replaceProviders(_ replacements: [UsageProvider]) {
        let removed = Set(providers.map(\.id)).subtracting(replacements.map(\.id))
        providers = replacements
        for id in removed {
            lastGood.removeValue(forKey: id)
            archive.forget(id)
        }
        // A fetch already in flight was started against the old list, and
        // would finish by writing the old list's snapshots over the new ones.
        refreshTask?.cancel()
        isRefreshing = false
        snapshots = replacements.filter { !disconnected.contains($0.id) }.map { provider in
            if let current = snapshots.first(where: { $0.id == provider.id }) { return current }
            guard let remembered = lastGood[provider.id] else { return Self.placeholder(provider) }
            var snapshot = remembered.snapshot
            snapshot.status = .stale(since: remembered.fetchedAt)
            return snapshot
        }
        refreshNow()
    }

    /// Enough to list the providers in settings without exposing them.
    var providerSummaries: [ProviderSummary] {
        providers.map {
            ProviderSummary(id: $0.id, kind: $0.kind, name: $0.displayName,
                            glyph: $0.glyph, account: $0.account(),
                            signIn: $0.signInRoute)
        }
    }

    func start() {
        refreshNow()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Waking up is the one moment the numbers are guaranteed to be wrong.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        isRefreshing = false
        // Block-based observers are not removed by `removeObserver(self)`.
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// How long a reading stays fresh enough that reaching for the notch is not
    /// worth a request. Well under the refresh interval, so unfolding still
    /// buys you a newer number than the timer would have.
    static let unfoldCooldown: TimeInterval = 15

    /// Refetch because the notch was opened — unless it was opened a moment ago.
    ///
    /// The notch unfolds whenever the pointer brushes the screen edge, so this
    /// is asked far more often than it should answer. A cooldown rather than a
    /// debounce: the first unfold after it lapses fetches immediately, which is
    /// the one that matters, and the ones in between cost nothing. The timer
    /// shares the same clock, so an unfold seconds after a scheduled fetch is
    /// free as well.
    func refreshIfStale(cooldown: TimeInterval = UsageStore.unfoldCooldown) {
        let waited = lastAttempt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard waited >= cooldown else { return }
        refreshNow()
    }

    func refreshNow() {
        guard !isRefreshing else {
            Log.usage.notice("refresh skipped: one already in flight")
            return
        }
        isRefreshing = true
        lastAttempt = Date()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            // A cancelled refresh was superseded by another; the flag is that
            // one's to clear, not this one's.
            guard !Task.isCancelled else { return }
            self?.isRefreshing = false
        }
    }

    func refresh() async {
        let live = providers.filter { !disconnected.contains($0.id) }
        refreshing = Set(live.map(\.id))
        defer { refreshing = [] }
        var next: [ProviderSnapshot] = []
        for provider in live {
            next.append(await snapshot(from: provider))
        }
        // Superseded mid-flight by `replaceProviders`: these are the old
        // list's readings, and writing them would bring back cells that
        // have just been removed.
        guard !Task.isCancelled else { return }
        snapshots = next
    }

    /// Refetch one provider, leaving the others alone.
    ///
    /// Deliberately not routed through `refreshNow`: asking one cell for a fresh
    /// reading should not spend every other provider's rate-limit budget, and
    /// Claude's in particular is easy to exhaust.
    func refresh(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              !disconnected.contains(providerID),
              !refreshing.contains(providerID) else { return }

        refreshing.insert(providerID)
        Task { [weak self] in
            let fresh = await self?.snapshot(from: provider)
            guard let self, let fresh else { return }
            if let index = self.snapshots.firstIndex(where: { $0.id == providerID }) {
                self.snapshots[index] = fresh
            }
            // A beat of visible work even when the answer was instant: a spinner
            // that flashes for one frame reads as a glitch, not as a refresh.
            try? await Task.sleep(nanoseconds: 380_000_000)
            self.refreshing.remove(providerID)
        }
    }

    /// Sign out of one provider: discard anything of its account that this app
    /// is holding, and stop reading it.
    ///
    /// Deliberately more than `disconnected` alone. Switching a provider off
    /// stops the *next* read; it leaves the last one archived, so the numbers
    /// come back on the next launch. Someone who presses Sign out means those
    /// numbers to be gone.
    ///
    /// What it cannot do is end the session at the vendor: for every provider
    /// shipping today the credential belongs to Claude Code, Cursor or Codex,
    /// and deleting their keychain item would sign the user out of an app they
    /// did not ask us to touch. `SignInRoute.signOutCaveat` says so on the row.
    func signOut(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }

        snapshots.removeAll { $0.id == providerID }
        lastGood.removeValue(forKey: providerID)
        archive.forget(providerID)

        Task { await provider.signOut() }
    }

    /// Take the user to wherever this provider's account is signed into.
    ///
    /// Three different places, because the providers differ in what they own: a
    /// `WebSessionProvider` presents its own modal, Cursor and Codex hold the
    /// credential in their app so the app is launched, and Claude Code is a
    /// command with nothing to open — the row's guidance is all there is.
    /// Returns whether anything was actually opened, so the sheet can say so
    /// when nothing was.
    @discardableResult
    func signIn(providerID: String) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return false }

        // Already holding a usable credential: connecting is the whole job, and
        // throwing up a sign-in window over a signed-in account is just noise.
        if provider.account() != nil {
            refresh(providerID: providerID)
            return true
        }

        return openAccountSource(providerID: providerID)
    }

    /// Ask macOS for this provider's credential again.
    ///
    /// The remedy for a declined keychain prompt. Dropping the in-memory copy
    /// first is the part that matters: a plain refresh is served from the cache
    /// whenever the token is still valid, so the keychain is never touched and
    /// the prompt never returns — the button would appear to do nothing.
    func reauthorize(providerID: String) {
        providers.first { $0.id == providerID }?.forgetCachedCredential()
        refresh(providerID: providerID)
    }

    /// Take the user to where this provider's account is *changed*.
    ///
    /// Same destination as signing in, but unconditional: switching accounts is
    /// something you do while already signed in, so the shortcut `signIn` takes
    /// when a credential exists is exactly wrong here.
    ///
    /// Codenotch cannot switch the account itself. The credential belongs to
    /// Claude Code, Cursor or Codex, and the most this can honestly do is open
    /// the thing that owns it.
    @discardableResult
    func openAccountSource(providerID: String) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return false }

        switch provider.signInRoute {
        case .modal:
            provider.presentSignIn()
            return true
        case .openApp(let bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return false }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return true
        case .guidance:
            // Claude Code: nothing to open. The row's guidance is the whole
            // answer, so the sheet has to show it rather than pretend.
            return false
        }
    }

    private func snapshot(from provider: UsageProvider) async -> ProviderSnapshot {
        do {
            let fresh = try await provider.fetchSnapshot()
            lastGood[provider.id] = (fresh, Date())
            archive.save(lastGood)
            Log.usage.debug("\(provider.id, privacy: .public): \(fresh.windows.count) window(s)")
            return fresh
        } catch {
            Log.usage.error("\(provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return degraded(provider: provider, error: error)
        }
    }

    /// A failed fetch never invents a number: it either re-shows the last good
    /// one marked stale, or shows the cell with no reading at all.
    private func degraded(provider: UsageProvider, error: Error) -> ProviderSnapshot {
        let status = Self.status(for: error)

        // Some failures are statements about the account rather than a hiccup:
        // signed out, or a plan that meters nothing. Re-showing an old reading
        // through one of those would present a number that is no longer true —
        // and, after an endpoint change, one that came from somewhere we no
        // longer read. So the remembered reading is dropped, not dimmed.
        if Self.supersedesHistory(status) {
            lastGood[provider.id] = nil
            archive.save(lastGood)
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        guard let previous = lastGood[provider.id] else {
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        // A stale-but-recent reading is still worth showing undimmed; past the
        // window it gets marked, and the ring dims.
        let age = Date().timeIntervalSince(previous.fetchedAt)
        var snapshot = previous.snapshot
        snapshot.status = age > staleAfter ? .stale(since: previous.fetchedAt) : previous.snapshot.status
        return snapshot
    }

    /// True when the new status makes any remembered reading untrue rather than
    /// merely old.
    static func supersedesHistory(_ status: ProviderStatus) -> Bool {
        switch status {
        case .needsAuth, .unsupported: return true
        // A refusal says nothing about the reading — the credential is there
        // and still valid, we were simply not let in to re-read it. Discarding
        // the last number would punish someone for pressing the wrong button.
        case .accessDenied:            return false
        case .ok, .stale, .error:      return false
        }
    }

    /// Exposed for the tests: the store never invents a reading, so what a
    /// failure looks like is worth pinning down.
    static func statusForTesting(_ error: Error) -> ProviderStatus { status(for: error) }

    private static func status(for error: Error) -> ProviderStatus {
        switch error {
        case UsageProviderError.needsAuth:
            return .needsAuth
        case UsageProviderError.credentialExpired:
            // Ages the reading rather than discarding it: the number was true
            // when it was taken, and the token will refresh itself in the
            // ordinary course of using the app that owns it.
            return .stale(since: Date())
        case UsageProviderError.rateLimited:
            // Not an error the user can do anything about, and the last good
            // reading is still roughly true, so it reads as staleness.
            return .stale(since: Date())
        case UsageProviderError.accessDenied:
            return .accessDenied
        case UsageProviderError.nothingMetered(let why):
            return .unsupported(why)
        case UsageProviderError.badResponse(let code):
            return .error("HTTP \(code)")
        default:
            return .error((error as NSError).localizedDescription)
        }
    }

    private static func placeholder(_ provider: UsageProvider) -> ProviderSnapshot {
        ProviderSnapshot(
            id: provider.id,
            displayName: provider.displayName,
            glyph: provider.glyph,
            fidelity: .official,
            status: .stale(since: .distantPast),
            windows: [],
            kind: provider.kind
        )
    }
}
