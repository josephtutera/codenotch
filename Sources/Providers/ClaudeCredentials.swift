import CryptoKit
import Foundation
import Security

/// The OAuth token Claude Code keeps in the login keychain.
///
/// Codenotch only ever *reads* this item. Refreshing is deliberately left to
/// Claude Code: minting a new token would mean writing a credential this app
/// does not own, so when the token expires the notch says `needsAuth` and waits
/// for Claude Code to refresh it in the ordinary course of being used.
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date
    /// "pro", "max", and so on — enough to show which plan the readings are for.
    let subscriptionType: String?

    var isExpired: Bool { expiresAt <= Date() }

    /// The item Claude Code writes for its default directory, `~/.claude`.
    static let defaultService = "Claude Code-credentials"

    /// The keychain item Claude Code writes for a configuration directory.
    ///
    /// The default directory owns the plain name. Any other directory — one
    /// named by `CLAUDE_CONFIG_DIR` — gets the first eight hex digits of the
    /// path's SHA-256 appended, which is how one Mac holds several Claude Code
    /// logins at once without them overwriting each other. Claude Code's rule,
    /// not ours, so it is pinned by a test on the shape and checked against the
    /// real item the first time a second account is signed in.
    static func keychainService(directory: String?) -> String {
        guard let directory else { return defaultService }
        let digest = SHA256.hash(data: Data(directory.utf8))
        let prefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(defaultService)-\(prefix)"
    }

    /// Where Claude Code writes the login instead when the keychain refuses —
    /// locked in an SSH session, say. Read as a fallback for the same reason
    /// Claude Code writes it as one.
    static func fallbackFile(directory: URL) -> URL {
        directory.appendingPathComponent(".credentials.json")
    }

    /// The shape of the item, which is the same in the keychain and the file.
    static func decode(_ data: Data) throws -> ClaudeCredentials {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                /// Milliseconds since the epoch.
                let expiresAt: Double
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UsageProviderError.needsAuth
        }
        return ClaudeCredentials(
            accessToken: payload.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: payload.claudeAiOauth.expiresAt / 1000),
            subscriptionType: payload.claudeAiOauth.subscriptionType
        )
    }

    /// Whether macOS refused a credential that exists, rather than failing to
    /// find one.
    ///
    /// `errSecAuthFailed` and `userCanceled` are what Deny produces;
    /// `interactionNotAllowed` is the same refusal arriving without a prompt.
    /// All three mean the item is there and we were not let in.
    static func wasRefused(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecUserCanceled
            || status == errSecInteractionNotAllowed
    }

    /// Which keychain refusal this was. "Not found" means Claude Code has never
    /// signed in; -25308 or -128 mean the item exists but this app is not on its
    /// access list. Those need entirely different advice, so the log says which.
    static func explain(_ status: OSStatus) -> String {
        switch status {
        case errSecItemNotFound:          return "no such item — Claude Code has not signed in"
        case errSecInteractionNotAllowed: return "access not permitted without interaction"
        case errSecUserCanceled:          return "the access prompt was dismissed or denied"
        case errSecAuthFailed:            return "authorisation failed"
        default:
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
        }
    }
}

/// Reads one Claude Code login, wherever that copy of Claude Code keeps it.
///
/// One per account: each configuration directory is a separately signed-in
/// copy of Claude Code with its own keychain item, and each item is read once
/// and held until it changes — see `CredentialCache`. Claude Code rotates the
/// token roughly hourly, so this is about one keychain read an hour per account
/// instead of two a minute.
final class ClaudeCredentialStore: Sendable {
    let service: String
    let fallbackFile: URL
    private let cache: CredentialCache<ClaudeCredentials>

    /// `directory` is the account's `CLAUDE_CONFIG_DIR`, or nil for `~/.claude`.
    init(directory: String? = nil) {
        service = ClaudeCredentials.keychainService(directory: directory)
        fallbackFile = ClaudeCredentials.fallbackFile(
            directory: URL(fileURLWithPath: directory
                ?? ConfiguredAccount.defaultDirectory(for: .claude))
        )
        cache = CredentialCache { $0.isExpired }
    }

    /// Forget the held copy. Call when the server rejects it: signing into a
    /// different account replaces the keychain item, and the copy in hand is
    /// then wrong despite not having expired.
    func forgetCached() { cache.forget() }

    /// Reads whatever is stored, expired or not. Judging expiry is the caller's
    /// job, because "signed out" and "the token has aged out overnight" call for
    /// different behaviour and only one of them is worth alarming anyone about.
    func load() throws -> ClaudeCredentials {
        try cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: service) ?? fileModifiedAt() },
            reload: read
        )
    }

    /// The fallback file's stamp, so the cache can tell whether it moved.
    private func fileModifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fallbackFile.path))?[.modificationDate] as? Date
    }

    private func read() throws -> ClaudeCredentials {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            return try ClaudeCredentials.decode(data)
        }
        if status == errSecItemNotFound, let data = try? Data(contentsOf: fallbackFile) {
            Log.usage.debug("no keychain item \(self.service, privacy: .public); reading \(self.fallbackFile.path, privacy: .public)")
            return try ClaudeCredentials.decode(data)
        }

        // The status matters: "not found" means Claude Code has never signed
        // in, whereas -25308 (interaction not allowed) or -128 (user cancelled)
        // mean the item is there but this app is not on its access list. Those
        // need very different advice, so record which.
        Log.usage.error("keychain read of \(self.service, privacy: .public) failed: OSStatus \(status) (\(ClaudeCredentials.explain(status), privacy: .public))")
        throw ClaudeCredentials.wasRefused(status)
            ? UsageProviderError.accessDenied
            : UsageProviderError.needsAuth
    }
}

/// The account a copy of Claude Code is signed in as, from the profile it
/// caches beside its settings. The credential itself carries no address, and
/// with two Claude accounts on one Mac the address is the only thing that says
/// which ring is which.
enum ClaudeProfile {
    /// The default copy keeps it at `~/.claude.json` — beside `~/.claude`, not
    /// inside it. A copy pointed at `CLAUDE_CONFIG_DIR` keeps it in that
    /// directory.
    static func file(directory: String?, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: directory ?? home).appendingPathComponent(".claude.json")
    }

    static func emailAddress(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return account["emailAddress"] as? String
    }
}
