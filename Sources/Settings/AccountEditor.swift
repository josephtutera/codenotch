import SwiftUI

/// Names an account and says where its copy of the tool lives.
///
/// Adding an account is naming a directory: a second copy of Claude Code or
/// Codex, pointed at a folder of its own, signed in separately. This sheet
/// picks the name and the folder; the signing in happens in a terminal, with
/// the command the account's row then shows.
struct AccountEditor: View {
    enum Target: Identifiable {
        case new(ProviderKind)
        case existing(ConfiguredAccount)

        var id: String {
            switch self {
            case .new(let kind):         return "new.\(kind.rawValue)"
            case .existing(let account): return account.id
            }
        }
    }

    let target: Target
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var directory: String
    /// The folder follows the name — "Max" suggests `~/.claude-max` — until
    /// the folder is typed in, after which the name leaves it alone.
    @State private var directoryWasEdited: Bool

    init(target: Target, preferences: Preferences) {
        self.target = target
        self.preferences = preferences
        switch target {
        case .new(let kind):
            _name = State(initialValue: "")
            _directory = State(initialValue: Self.suggestion(kind: kind, name: ""))
            _directoryWasEdited = State(initialValue: false)
        case .existing(let account):
            _name = State(initialValue: account.name)
            _directory = State(initialValue: account.directory
                ?? ConfiguredAccount.defaultDirectory(for: account.kind))
            _directoryWasEdited = State(initialValue: true)
        }
    }

    private var kind: ProviderKind {
        switch target {
        case .new(let kind):         return kind
        case .existing(let account): return account.kind
        }
    }

    private var existing: ConfiguredAccount? {
        if case .existing(let account) = target { return account }
        return nil
    }

    /// The tool's own folder: renamable, but it lives where the tool put it.
    private var isDefault: Bool { existing?.isDefault ?? false }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedDirectory: String { directory.trimmingCharacters(in: .whitespaces) }

    private var canSave: Bool {
        !trimmedName.isEmpty && (isDefault || !trimmedDirectory.isEmpty)
    }

    private var title: String {
        switch target {
        case .new(let kind):         return "Add a \(kind.toolName) account"
        case .existing(let account): return "Edit \(account.displayName)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            Form {
                TextField("Name", text: $name, prompt: Text(kind == .claude ? "Max" : "Work"))
                TextField("Folder", text: $directory)
                    .font(.body.monospaced())
                    .disabled(isDefault)
                    .foregroundStyle(isDefault ? .secondary : .primary)
            }
            .formStyle(.columns)
            .onChange(of: name) { _, newName in
                guard !directoryWasEdited else { return }
                directory = Self.suggestion(kind: kind, name: newName)
            }
            .onChange(of: directory) { _, newValue in
                if newValue != Self.suggestion(kind: kind, name: name) { directoryWasEdited = true }
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let existing, !existing.isDefault {
                    Button("Remove", role: .destructive) {
                        preferences.removeAccount(id: existing.id)
                        dismiss()
                    }
                    .help("Takes the account off the notch and forgets its readings. "
                          + "The sign-in in its folder is left alone.")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var explanation: String {
        if isDefault {
            return "This is \(kind.toolName)'s own folder, so only the name can change here."
        }
        switch kind {
        case .claude:
            return "A separate copy of Claude Code keeps this account's login in the folder "
                 + "above. After adding it, run the command on its row in a terminal and "
                 + "use /login there. Only that copy refreshes this account's token, so "
                 + "the reading goes stale if it is never used."
        case .codex:
            return "A separate copy of Codex keeps this account's login in the folder above. "
                 + "After adding it, run the command on its row in a terminal. The Codex "
                 + "app itself always uses the default folder."
        default:
            return ""
        }
    }

    private func save() {
        // Expanded here, once: the tool hashes the path it is given to name
        // its keychain item, so the same spelling has to be used everywhere.
        let folder = (trimmedDirectory as NSString).expandingTildeInPath
        switch target {
        case .new(let kind):
            preferences.addAccount(kind: kind, name: trimmedName, directory: folder)
        case .existing(var account):
            account.name = trimmedName
            if !account.isDefault { account.directory = folder }
            preferences.updateAccount(account)
        }
    }

    private static func suggestion(kind: ProviderKind, name: String) -> String {
        let slug = ConfiguredAccount.slug(for: name)
        return ConfiguredAccount.suggestedDirectory(kind: kind, slug: slug.isEmpty ? "account" : slug)
    }
}
