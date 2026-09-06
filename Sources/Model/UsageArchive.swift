import Foundation

/// The last good reading for each provider, remembered across launches.
///
/// Without this, a cold start that cannot reach the endpoint — rate limited,
/// offline, token expired — shows nothing at all, which is the least useful
/// thing the notch could do. A remembered reading is dimmed and dated, but a
/// dated number you can see beats a blank ring.
struct UsageArchive {
    private struct Entry: Codable {
        let id: String
        let displayName: String
        let glyph: ProviderGlyph
        let fidelity: Fidelity
        let windows: [LimitWindow]
        let fetchedAt: Date
        /// Added with accounts. Absent from older archives, where the id *was*
        /// the tool.
        var kind: ProviderKind?
        var accountLabel: String?
    }

    private let defaults: UserDefaults
    private let key = "lastGoodReadings"
    /// One key per bucket, which is not the same as one key per account:
    /// every Claude account shares a penalty under `claude`, because the
    /// endpoint refuses them together (see `ClaudeRateLimit`). That is the key
    /// the single-account build wrote, so an update mid-penalty waits it out.
    private func backoffKey(for providerID: String) -> String {
        providerID == "claude" ? "backoffUntil" : "backoffUntil.\(providerID)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Back-off

    /// When the endpoint may next be called, remembered across launches.
    ///
    /// Without this, every relaunch starts with a clean slate and fires a
    /// request immediately — so a development loop of `make run` walks straight
    /// into the rate limit it is being punished by, and keeps the punishment
    /// alive. Which is exactly what happened.
    func loadBackoffUntil(for providerID: String) -> Date? {
        let key = backoffKey(for: providerID)
        guard let date = defaults.object(forKey: key) as? Date, date > Date() else {
            return nil
        }
        return date
    }

    func saveBackoffUntil(_ date: Date?, for providerID: String) {
        let key = backoffKey(for: providerID)
        if let date {
            defaults.set(date, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func load() -> [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }

        var result: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
        for entry in entries {
            let snapshot = ProviderSnapshot(
                id: entry.id,
                displayName: entry.displayName,
                glyph: entry.glyph,
                fidelity: entry.fidelity,
                status: .stale(since: entry.fetchedAt),
                windows: entry.windows,
                kind: entry.kind ?? ProviderKind(rawValue: entry.id) ?? .other,
                accountLabel: entry.accountLabel,
                fetchedAt: entry.fetchedAt
            )
            result[entry.id] = (snapshot, entry.fetchedAt)
        }
        return result
    }

    func save(_ readings: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)]) {
        let entries = readings.values.map {
            Entry(
                id: $0.snapshot.id,
                displayName: $0.snapshot.displayName,
                glyph: $0.snapshot.glyph,
                fidelity: $0.snapshot.fidelity,
                windows: $0.snapshot.windows,
                fetchedAt: $0.fetchedAt,
                kind: $0.snapshot.kind,
                accountLabel: $0.snapshot.accountLabel
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Drop what we remember about one provider.
    ///
    /// Signing out has to reach this, or the notch keeps showing the last
    /// reading — dimmed and dated, but still that account's numbers, still on
    /// screen after the next launch.
    func forget(_ providerID: String) {
        var readings = load()
        readings.removeValue(forKey: providerID)
        save(readings)
    }
}
