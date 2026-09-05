import Foundation

/// Builds the providers and the activity monitors for a set of accounts.
///
/// One place, because the two lists have to agree: a provider with no monitor
/// never shows whether its agent is working, and a monitor with no provider
/// publishes sessions to a cell that does not exist.
enum ProviderFactory {
    /// Claude accounts, then Cursor, then Codex accounts, then Antigravity —
    /// the order the notch has always shown its cells in, with each tool's
    /// accounts kept together so two rings of one glyph sit side by side.
    static func providers(for accounts: [ConfiguredAccount]) -> [UsageProvider] {
        let claude: [UsageProvider] = accounts
            .filter { $0.kind == .claude }
            .map { ClaudeOAuthProvider(account: $0) }
        let codex: [UsageProvider] = accounts
            .filter { $0.kind == .codex }
            .map { CodexLocalProvider(account: $0) }
        return claude + [CursorLocalProvider()] + codex + [AntigravityProvider()]
    }

    /// One monitor per cell, keyed by the provider it reports on. A Claude
    /// account's sessions live under its own directory, and a Codex account's
    /// rollouts under its own home, so each account watches its own.
    @MainActor
    static func monitors(for accounts: [ConfiguredAccount]) -> [String: any AgentActivityMonitor] {
        var monitors: [String: any AgentActivityMonitor] = [
            "cursor": CursorActivityMonitor(),
            "gemini": AntigravityActivityMonitor()
        ]
        for account in accounts {
            switch account.kind {
            case .claude:
                monitors[account.id] = ClaudeSessionMonitor(
                    directory: account.directoryURL.appendingPathComponent("sessions")
                )
            case .codex:
                monitors[account.id] = CodexActivityMonitor(
                    stateStore: CodexStore.stateURL(home: account.directoryURL),
                    desktopStore: CodexStore.desktopStoreURL(home: account.directoryURL)
                )
            default:
                break
            }
        }
        return monitors
    }
}
