import Foundation

/// One account Codenotch reads: which tool, what the user calls it, and the
/// directory that tool keeps the login in.
///
/// Claude Code and Codex each keep their login under one directory — `~/.claude`
/// and `~/.codex` by default — and each can be pointed somewhere else with an
/// environment variable, `CLAUDE_CONFIG_DIR` and `CODEX_HOME`. A second
/// directory is a second, independently signed-in copy of the tool, which is
/// the whole trick: Codenotch still borrows every credential and signs in to
/// nothing, it just knows about more than one place to borrow from.
struct ConfiguredAccount: Codable, Equatable, Identifiable {
    let kind: ProviderKind
    /// Stable key for the archive and the connection choice. Empty for the
    /// tool's default directory, so those ids stay `claude` and `codex` and the
    /// readings and choices people already have survive.
    let slug: String
    /// What the user calls it — "Team", "Max", "Gmail". Empty means unnamed.
    var name: String
    /// Absolute path, or nil for the tool's default directory.
    var directory: String?

    var id: String { slug.isEmpty ? kind.rawValue : "\(kind.rawValue).\(slug)" }

    /// The tool's own directory, which cannot be moved from here.
    var isDefault: Bool { slug.isEmpty }

    /// "Claude" unnamed, "Claude Max" named.
    var displayName: String {
        name.isEmpty ? kind.displayName : "\(kind.displayName) \(name)"
    }

    var directoryURL: URL {
        URL(fileURLWithPath: directory ?? Self.defaultDirectory(for: kind))
    }

    /// Where the tool keeps itself when nothing says otherwise.
    static func defaultDirectory(for kind: ProviderKind, home: String = NSHomeDirectory()) -> String {
        switch kind {
        case .claude: return home + "/.claude"
        case .codex:  return home + "/.codex"
        default:      return home
        }
    }

    /// The variable that points the tool at a directory.
    static func environmentVariable(for kind: ProviderKind) -> String? {
        switch kind {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex:  return "CODEX_HOME"
        default:      return nil
        }
    }

    /// The `VAR=dir` prefix that makes a command use this account.
    ///
    /// Nil for a default directory: the tool already reads it, and prefixing
    /// the variable with the default would suggest it needs to be.
    var environmentPrefix: String? {
        guard let directory, let variable = Self.environmentVariable(for: kind) else { return nil }
        return "\(variable)=\"\(directory)\""
    }

    /// The command that signs this directory in. The Claude Code and Codex
    /// apps cannot sign a second directory in; only their command lines can.
    var signInCommand: String? {
        guard let prefix = environmentPrefix else { return nil }
        switch kind {
        case .claude: return "\(prefix) claude"
        case .codex:  return "\(prefix) codex login"
        default:      return nil
        }
    }

    /// What to do after the command, where the command alone is not the login.
    var signInNote: String? {
        switch kind {
        case .claude where environmentPrefix != nil:
            return "then use /login in that Claude Code, and keep using it there — "
                 + "only that copy refreshes this account's token."
        default:
            return nil
        }
    }

    /// Make the folder, so the tool can use it. Codex refuses a `CODEX_HOME`
    /// that does not exist rather than creating it — "Error loading
    /// configuration" — and Claude Code creates its own, so making it here
    /// costs nothing there. Nothing for the default directory: it is the
    /// tool's, and the tool made it.
    func createDirectoryIfMissing(fileManager: FileManager = .default) throws {
        guard let directory else { return }
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    // MARK: - The shipped pair

    static let defaultClaude = ConfiguredAccount(kind: .claude, slug: "", name: "", directory: nil)
    static let defaultCodex  = ConfiguredAccount(kind: .codex, slug: "", name: "", directory: nil)

    /// What every copy starts with: the two tools' own directories, unnamed.
    static let defaults: [ConfiguredAccount] = [defaultClaude, defaultCodex]

    // MARK: - Naming

    /// A key from a name: "Pro 2" becomes `pro-2`. ASCII letters and digits
    /// only, because the slug is part of a provider id that ends up in
    /// `UserDefaults` keys and log lines.
    static func slug(for name: String) -> String {
        var out = ""
        var gap = false
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if gap, !out.isEmpty { out += "-" }
                gap = false
                out.unicodeScalars.append(scalar)
            } else {
                gap = true
            }
        }
        return out
    }

    /// Where a new account's copy of the tool should keep itself: beside the
    /// default, named after the account — `~/.claude-max`.
    static func suggestedDirectory(kind: ProviderKind, slug: String,
                                   home: String = NSHomeDirectory()) -> String {
        "\(defaultDirectory(for: kind, home: home))-\(slug)"
    }
}
