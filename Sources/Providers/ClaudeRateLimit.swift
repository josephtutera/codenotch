import Foundation

/// The rate limit belongs to the endpoint, not to an account.
///
/// Two Claude accounts are two tokens, so a penalty was kept per account. The
/// log says that is not how the endpoint behaves: polled a second apart from
/// one machine, both accounts are refused within the same millisecond, and each
/// one's penalty was then re-tripped by its sibling still polling — 60s, 120,
/// 240, 480, while the rings sat dimmed on remembered numbers.
///
/// So there is one penalty and every Claude account serves it. It costs the
/// innocent account a reading it might have been given; it buys not walking
/// back into the limit on the next tick, which is what was actually happening.
actor ClaudeRateLimit {
    static let shared = ClaudeRateLimit()

    /// When the endpoint may next be called at all.
    private var retryNoEarlierThan: Date?
    /// How many 429s in a row, which is what the wait doubles against.
    private(set) var attempt = 0

    private let archive: UsageArchive

    init(archive: UsageArchive = UsageArchive()) {
        self.archive = archive
        // Pick the penalty up where the last run left it, or relaunching during
        // one spends an attempt extending it.
        self.retryNoEarlierThan = archive.loadBackoffUntil()
    }

    /// How much of the penalty is left, or nil when there is none to serve.
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard let retryNoEarlierThan, retryNoEarlierThan > now else { return nil }
        return retryNoEarlierThan.timeIntervalSince(now)
    }

    /// A 429. Returns how many in a row, for the log.
    ///
    /// Never shortens a penalty already being served: two accounts refused in
    /// the same second must not have the second refusal shrink the first one's
    /// wait.
    func penalise(retryAfter: TimeInterval, now: Date = Date()) -> Int {
        attempt += 1
        let until = now.addingTimeInterval(retryAfter)
        retryNoEarlierThan = max(until, retryNoEarlierThan ?? until)
        archive.saveBackoffUntil(retryNoEarlierThan)
        return attempt
    }

    /// A reading got through, so the window has room again — for every account,
    /// since they share it.
    func clear() {
        guard retryNoEarlierThan != nil || attempt > 0 else { return }
        retryNoEarlierThan = nil
        attempt = 0
        archive.saveBackoffUntil(nil)
    }
}
