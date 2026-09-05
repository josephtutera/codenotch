import Foundation
import SQLite3
import os

/// Reads Codex usage from the rollout log of the thread it last worked on.
///
/// No credential and no network: Codex records its own rate-limit snapshots
/// locally, the same bargain as reading Claude Code's session files. The newest
/// rollout is found through Codex's thread index rather than by walking the
/// sessions tree, which holds thousands of files.
actor CodexLocalProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let kind = ProviderKind.codex
    nonisolated let glyph = ProviderGlyph.openai

    /// Which copy of Codex this reads. Its `CODEX_HOME` holds the login, the
    /// thread index and the rollouts, and it is what the app server is told
    /// to use — so one Mac can carry a Codex account per directory.
    private nonisolated let configured: ConfiguredAccount
    private nonisolated let home: URL
    private let stateStore: URL
    /// Only the tail matters — the newest snapshot is at the end of the file.
    private let tailBytes = 256 * 1024

    init(account: ConfiguredAccount = .defaultCodex) {
        id = account.id
        displayName = account.displayName
        configured = account
        home = account.directoryURL
        stateStore = CodexStore.stateURL(home: home)
    }

    /// The desktop app can only ever sign in `~/.codex`, so a second directory
    /// is signed in from a terminal, and the row has to say so.
    nonisolated var signInRoute: SignInRoute {
        configured.signInCommand == nil
            ? .openApp(bundleID: "com.openai.codex", name: "Codex")
            : .guidance("Sign in with the command below — the Codex app cannot sign a "
                        + "second directory in.")
    }

    nonisolated func account() -> ProviderAccount? {
        CodexCredentials.account(from: CodexCredentials.authURL(home: home))
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // No login in this home means nothing to read — not "no threads yet",
        // which is what an empty home looks like from the rollout side, and
        // not worth spawning an app server to be told.
        guard FileManager.default.fileExists(atPath: CodexCredentials.authURL(home: home).path) else {
            throw UsageProviderError.needsAuth
        }

        // Codex itself first. The rollout below is a record of what was true
        // during the last turn; this is what is true now, and the two disagree
        // by however long it has been since Codex was used.
        if let live = await liveReading(), !live.windows.isEmpty {
            return ProviderSnapshot(
                id: id, displayName: displayName, glyph: glyph,
                fidelity: .official, status: .ok, windows: live.windows,
                headlineID: "primary", block: live.block,
                kind: kind, accountLabel: account()?.label
            )
        }

        guard let rollout = CodexStore.newestRollout(in: stateStore) else {
            throw UsageProviderError.nothingMetered("No Codex threads on this machine yet")
        }
        let text = try tail(of: rollout)
        let windows = try CodexUsage.windows(fromRollout: text)

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: Self.status(recordedAt: CodexUsage.recordedAt(inRollout: text)),
            windows: windows,
            headlineID: "primary",
            kind: kind,
            accountLabel: account()?.label
        )
    }

    /// Ask Codex's app server for the live figure.
    ///
    /// Off the actor: spawning a process and waiting on a pipe is blocking
    /// work, and doing it here would stall every other read this provider owes.
    /// Nil rather than throwing when Codex is not installed or does not answer
    /// — that is the ordinary case for someone who does not use it, and the
    /// caller has an honest fallback either way.
    private func liveReading() async -> (windows: [LimitWindow], block: UsageBlock?)? {
        guard let executable = CodexBridge.executable() else { return nil }
        let home = self.home
        let answer = await Task.detached(priority: .utility) { () -> Data? in
            do {
                return try CodexBridge.rateLimits(executable: executable, home: home)
            } catch {
                Log.usage.error("codex: app server failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
        guard let answer else { return nil }
        let windows = CodexBridge.windows(in: answer)
        if windows.isEmpty {
            Log.usage.error("codex: app server answered with no windows we understood")
            return nil
        }
        let block = CodexBridge.block(in: answer)
        Log.usage.debug("codex: live reading, \(windows.count) window(s), blocked: \(block != nil)")
        return (windows, block)
    }

    /// How long a rollout's own snapshot counts as current.
    ///
    /// Codex does not publish usage; it writes what it saw into a file as it
    /// runs. So the file stops changing the moment you stop using Codex, and
    /// reading it still succeeds instantly — the *fetch* is fresh while the
    /// *reading* may be days old. Every other provider here asks a server and
    /// gets today's answer, which is why only this one needs the distinction.
    static let currentFor: TimeInterval = 5 * 60

    static func status(recordedAt: Date?, now: Date = Date()) -> ProviderStatus {
        // No timestamp to judge by: say stale rather than claim currency we
        // cannot support.
        guard let recordedAt else { return .stale(since: .distantPast) }
        return now.timeIntervalSince(recordedAt) <= currentFor
            ? .ok
            : .stale(since: recordedAt)
    }

    /// Reads the last chunk of a file rather than all of it: rollouts grow
    /// without bound and only the most recent snapshot is wanted.
    private func tail(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw UsageProviderError.nothingMetered("Codex's rollout could not be read")
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Shared access to Codex's local state.
enum CodexStore {
    /// `~/.codex`, where Codex keeps itself unless `CODEX_HOME` says otherwise.
    static var defaultHome: URL {
        URL(fileURLWithPath: ConfiguredAccount.defaultDirectory(for: .codex))
    }

    static var stateURL: URL { stateURL(home: defaultHome) }

    static func stateURL(home: URL) -> URL {
        home.appendingPathComponent("state_5.sqlite")
    }

    /// The desktop app's own thread catalogue.
    ///
    /// Codex's *rollouts* are written by the CLI and by the VS Code extension.
    /// The desktop app — ChatGPT.app, which is what most people mean by "Codex"
    /// now — writes none of them; it keeps its threads here instead, with
    /// `source_kind = 'chatgpt'`. Watching only the rollouts meant the notch
    /// could never see the desktop app working at all.
    static var desktopStoreURL: URL { desktopStoreURL(home: defaultHome) }

    static func desktopStoreURL(home: URL) -> URL {
        home.appendingPathComponent("sqlite/codex-dev.db")
    }

    /// The most recently touched desktop thread: when, and what it is called.
    static func newestDesktopThread(in url: URL) -> (title: String, updatedAt: Date)? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT source_updated_at, display_title, thread_id
            FROM local_thread_catalog ORDER BY source_updated_at DESC LIMIT 1
            """,
            columns: 3
        )
        guard let row = rows.first, let seconds = Double(row[0]) else { return nil }
        // Seconds since the epoch, with a fractional part — not the
        // milliseconds the `threads` table next door uses.
        let title = row[1].isEmpty ? "Codex" : row[1]
        return (title, Date(timeIntervalSince1970: seconds))
    }

    /// The rollout of the most recently touched thread.
    static func newestRollout(in store: URL) -> URL? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }

        let paths = SQLiteStore.rows(
            in: db,
            sql: "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8"
        )
        return paths
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
