import Foundation

/// Builds the providers for a set of accounts.
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
}
