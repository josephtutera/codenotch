import Foundation

/// Which tool a reading is borrowed from.
///
/// Distinct from a provider's `id` since accounts arrived: one tool can be read
/// for several accounts, each its own provider with its own id, and the UI keys
/// its wording, glyph and keychain behaviour on the tool rather than on the id.
/// Matching on the id string was fine while the two were the same thing; it
/// quietly stops being fine the moment a second Claude account is `claude.max`.
enum ProviderKind: String, Codable, Equatable, CaseIterable {
    case claude
    case cursor
    case codex
    /// The raw value stays `gemini`: it is the id archived readings and the
    /// user's connection choice were written under.
    case antigravity = "gemini"
    /// A stub, or a web session with no local tool behind it.
    case other

    /// Whether two accounts of this tool are two requests to one endpoint,
    /// and so have to be spaced out rather than sent together.
    ///
    /// The local ones are not: Codex reads a file this Mac already has, and
    /// Antigravity asks a language server on this machine. Nothing there can
    /// refuse a second caller for being the same caller.
    var sharesARemoteLimit: Bool {
        switch self {
        case .claude, .cursor:            return true
        case .codex, .antigravity, .other: return false
        }
    }

    /// What the tool is called, for rows and prompts.
    var toolName: String {
        switch self {
        case .claude:      return "Claude Code"
        case .cursor:      return "Cursor"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        case .other:       return "the tool that owns it"
        }
    }

    /// The name on the cell and the row, before any account name is added.
    var displayName: String {
        switch self {
        case .claude:      return "Claude"
        case .cursor:      return "Cursor"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        case .other:       return ""
        }
    }

    /// Whether the credential lives in the keychain, and so can be refused.
    /// Cursor and Codex read ordinary files and never prompt.
    var usesKeychain: Bool { self == .claude || self == .antigravity }

    /// Whether the tool keeps its login in a directory the user can point it
    /// at, so a second copy of the tool can be signed in to a second account.
    var supportsSeveralAccounts: Bool { self == .claude || self == .codex }
}
