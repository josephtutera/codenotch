import XCTest
@testable import Codenotch

/// Two accounts of one tool are two directories, and everything here follows
/// from that: the ids, the names, the keychain items, the command that signs
/// one in.
final class ConfiguredAccountTests: XCTestCase {
    /// The archive and the connection choice were written under `claude` and
    /// `codex`; the tools' own directories must keep those ids or every
    /// existing install loses its readings on update.
    func testTheDefaultsKeepTheIdsReadingsWereArchivedUnder() {
        XCTAssertEqual(ConfiguredAccount.defaultClaude.id, "claude")
        XCTAssertEqual(ConfiguredAccount.defaultCodex.id, "codex")
        XCTAssertTrue(ConfiguredAccount.defaultClaude.isDefault)
        XCTAssertEqual(ConfiguredAccount.defaults.map(\.id), ["claude", "codex"])
    }

    func testANamedAccountIsKeyedByItsSlug() {
        let max = ConfiguredAccount(kind: .claude, slug: "max", name: "Max",
                                    directory: "/Users/x/.claude-max")
        XCTAssertEqual(max.id, "claude.max")
        XCTAssertEqual(max.displayName, "Claude Max")
        XCTAssertFalse(max.isDefault)
    }

    func testAnUnnamedDefaultShowsTheToolAlone() {
        XCTAssertEqual(ConfiguredAccount.defaultCodex.displayName, "Codex")
        var named = ConfiguredAccount.defaultCodex
        named.name = "CarePilot"
        XCTAssertEqual(named.displayName, "Codex CarePilot")
        XCTAssertEqual(named.id, "codex", "naming the default must not move its id")
    }

    func testSlugsAreLowercaseASCIIWithDashes() {
        XCTAssertEqual(ConfiguredAccount.slug(for: "Pro 2"), "pro-2")
        XCTAssertEqual(ConfiguredAccount.slug(for: "  CarePilot  "), "carepilot")
        XCTAssertEqual(ConfiguredAccount.slug(for: "J.C.T. Jr"), "j-c-t-jr")
        XCTAssertEqual(ConfiguredAccount.slug(for: "Équipe"), "quipe")
        XCTAssertEqual(ConfiguredAccount.slug(for: "!!!"), "")
    }

    func testTheSuggestedDirectorySitsBesideTheDefault() {
        XCTAssertEqual(ConfiguredAccount.defaultDirectory(for: .claude, home: "/Users/x"),
                       "/Users/x/.claude")
        XCTAssertEqual(ConfiguredAccount.defaultDirectory(for: .codex, home: "/Users/x"),
                       "/Users/x/.codex")
        XCTAssertEqual(ConfiguredAccount.suggestedDirectory(kind: .claude, slug: "max", home: "/Users/x"),
                       "/Users/x/.claude-max")
    }

    func testTheSignInCommandNamesTheVariableAndTheFolder() {
        let claude = ConfiguredAccount(kind: .claude, slug: "max", name: "Max",
                                       directory: "/Users/x/.claude-max")
        XCTAssertEqual(claude.signInCommand, "CLAUDE_CONFIG_DIR=\"/Users/x/.claude-max\" claude")
        XCTAssertNotNil(claude.signInNote, "Claude Code still needs /login after launching")

        let codex = ConfiguredAccount(kind: .codex, slug: "gmail", name: "Gmail",
                                      directory: "/Users/x/.codex-gmail")
        XCTAssertEqual(codex.signInCommand, "CODEX_HOME=\"/Users/x/.codex-gmail\" codex login")
        XCTAssertNil(codex.signInNote)
    }

    /// The tool already reads its own directory; a command would suggest it
    /// needed telling.
    func testTheDefaultDirectoryNeedsNoCommand() {
        XCTAssertNil(ConfiguredAccount.defaultClaude.signInCommand)
        XCTAssertNil(ConfiguredAccount.defaultCodex.environmentPrefix)
    }

    /// Codex refuses a `CODEX_HOME` that does not exist rather than making it.
    func testItMakesItsFolderAndLeavesTheDefaultAlone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".codex-gmail").path

        let gmail = ConfiguredAccount(kind: .codex, slug: "gmail", name: "Gmail", directory: folder)
        try gmail.createDirectoryIfMissing()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNoThrow(try gmail.createDirectoryIfMissing(), "already there is fine")

        XCTAssertNoThrow(try ConfiguredAccount.defaultCodex.createDirectoryIfMissing(),
                         "the default directory is the tool's to make")
    }

    func testItRoundTripsThroughJSON() throws {
        let accounts = [
            ConfiguredAccount.defaultClaude,
            ConfiguredAccount(kind: .claude, slug: "max", name: "Max", directory: "/Users/x/.claude-max"),
            ConfiguredAccount.defaultCodex
        ]
        let data = try JSONEncoder().encode(accounts)
        XCTAssertEqual(try JSONDecoder().decode([ConfiguredAccount].self, from: data), accounts)
    }
}

/// Claude Code keys its keychain item to the directory it runs from, which is
/// what lets two of its logins share one login keychain.
final class ClaudeKeychainServiceTests: XCTestCase {
    func testTheDefaultDirectoryOwnsThePlainName() {
        XCTAssertEqual(ClaudeCredentials.keychainService(directory: nil), "Claude Code-credentials")
    }

    /// Pinned to a known digest, so a change in how the suffix is derived is
    /// caught here rather than as every second account silently reading
    /// nothing.
    func testAnotherDirectoryGetsEightHexDigitsOfItsPathHash() {
        XCTAssertEqual(ClaudeCredentials.keychainService(directory: "/Users/x/.claude-max"),
                       "Claude Code-credentials-74db0186")
        XCTAssertNotEqual(ClaudeCredentials.keychainService(directory: "/Users/x/.claude-team"),
                          ClaudeCredentials.keychainService(directory: "/Users/x/.claude-max"))
    }

    func testTheProfileSitsBesideTheDefaultDirectoryAndInsideAnyOther() {
        XCTAssertEqual(ClaudeProfile.file(directory: nil, home: "/Users/x").path,
                       "/Users/x/.claude.json")
        XCTAssertEqual(ClaudeProfile.file(directory: "/Users/x/.claude-max", home: "/Users/x").path,
                       "/Users/x/.claude-max/.claude.json")
    }

    func testTheAddressComesFromTheProfile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString).json")
        try Data(#"{"oauthAccount":{"emailAddress":"max@example.com","organizationName":"Org"}}"#.utf8)
            .write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(ClaudeProfile.emailAddress(in: file), "max@example.com")
        XCTAssertEqual(ClaudeProfile.label(in: file), "max@example.com · Org")
        XCTAssertNil(ClaudeProfile.emailAddress(in: file.appendingPathExtension("missing")))
    }

    /// Team and Max on one address differ only by organisation, and the
    /// personal organisation is named after the address, so it adds nothing.
    func testThePersonalOrganisationIsLeftOffTheLabel() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"oauthAccount":{"emailAddress":"me@example.com","organizationName":"me@example.com's Organization"}}"#.utf8)
            .write(to: file)
        XCTAssertEqual(ClaudeProfile.label(in: file), "me@example.com")

        try Data(#"{"oauthAccount":{"emailAddress":"me@example.com"}}"#.utf8).write(to: file)
        XCTAssertEqual(ClaudeProfile.label(in: file), "me@example.com", "no organisation at all is fine")
    }

    /// The fallback file Claude Code writes when the keychain refuses has the
    /// same shape as the keychain item, so one decoder serves both.
    func testTheFallbackFileDecodesLikeTheKeychainItem() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1900000000000,"subscriptionType":"max"}}"#
        let credentials = try ClaudeCredentials.decode(Data(json.utf8))
        XCTAssertEqual(credentials.accessToken, "t")
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertFalse(credentials.isExpired)
        XCTAssertEqual(ClaudeCredentials.fallbackFile(directory: URL(fileURLWithPath: "/Users/x/.claude-max")).path,
                       "/Users/x/.claude-max/.credentials.json")
    }
}

/// A Codex account is a `CODEX_HOME`, and everything read for it — the login,
/// the thread index, the app server's answer — has to come from that one home.
final class CodexAccountTests: XCTestCase {
    func testTheAppServerIsPointedAtTheAccountsHome() {
        let home = URL(fileURLWithPath: "/Users/x/.codex-gmail")
        let environment = CodexBridge.environment(home: home, base: ["PATH": "/usr/bin"])
        XCTAssertEqual(environment["CODEX_HOME"], "/Users/x/.codex-gmail")
        XCTAssertEqual(environment["PATH"], "/usr/bin", "the rest of the environment is kept")
    }

    /// A `CODEX_HOME` the app itself inherited would make the server answer
    /// for one account while the label came from another.
    func testAnInheritedHomeIsOverridden() {
        let home = URL(fileURLWithPath: "/Users/x/.codex")
        let environment = CodexBridge.environment(home: home, base: ["CODEX_HOME": "/elsewhere"])
        XCTAssertEqual(environment["CODEX_HOME"], "/Users/x/.codex")
    }

    func testEveryStoreLivesUnderTheHome() {
        let home = URL(fileURLWithPath: "/Users/x/.codex-gmail")
        XCTAssertEqual(CodexStore.stateURL(home: home).path, "/Users/x/.codex-gmail/state_5.sqlite")
        XCTAssertEqual(CodexStore.desktopStoreURL(home: home).path,
                       "/Users/x/.codex-gmail/sqlite/codex-dev.db")
        XCTAssertEqual(CodexCredentials.authURL(home: home).path, "/Users/x/.codex-gmail/auth.json")
    }
}

@MainActor
final class ProviderFactoryTests: XCTestCase {
    private let accounts = [
        ConfiguredAccount.defaultClaude,
        ConfiguredAccount(kind: .claude, slug: "max", name: "Max", directory: "/Users/x/.claude-max"),
        ConfiguredAccount.defaultCodex,
        ConfiguredAccount(kind: .codex, slug: "gmail", name: "Gmail", directory: "/Users/x/.codex-gmail")
    ]

    /// The order the notch has always shown, with each tool's accounts kept
    /// together so two rings of one glyph sit side by side.
    func testEachToolsAccountsStayTogetherInTheShippedOrder() {
        let providers = ProviderFactory.providers(for: accounts)
        XCTAssertEqual(providers.map(\.id),
                       ["claude", "claude.max", "cursor", "codex", "codex.gmail", "gemini"])
        XCTAssertEqual(providers.map(\.kind),
                       [.claude, .claude, .cursor, .codex, .codex, .antigravity])
        XCTAssertEqual(providers.map(\.displayName),
                       ["Claude", "Claude Max", "Cursor", "Codex", "Codex Gmail", "Antigravity"])
    }

    func testEveryProviderHasAMonitor() {
        let providers = ProviderFactory.providers(for: accounts).map(\.id)
        let monitors = ProviderFactory.monitors(for: accounts)
        XCTAssertEqual(Set(monitors.keys), Set(providers))
    }

    func testTheShippedPairIsWhatShippedBefore() {
        XCTAssertEqual(ProviderFactory.providers(for: ConfiguredAccount.defaults).map(\.id),
                       ["claude", "cursor", "codex", "gemini"])
    }
}

@MainActor
final class PreferencesAccountsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "PreferencesAccountsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAFreshInstallHasTheShippedPair() {
        XCTAssertEqual(Preferences(defaults: makeDefaults()).accounts, ConfiguredAccount.defaults)
    }

    func testAddingKeysOffTheNameAndAvoidsCollisions() {
        let preferences = Preferences(defaults: makeDefaults())
        let first = preferences.addAccount(kind: .claude, name: "Max", directory: "/x")
        let second = preferences.addAccount(kind: .claude, name: "Max", directory: "/y")
        XCTAssertEqual(first.id, "claude.max")
        XCTAssertEqual(second.id, "claude.max-2")
        // Beside the other Claude accounts, ahead of Codex.
        XCTAssertEqual(preferences.accounts.map(\.id), ["claude", "claude.max", "claude.max-2", "codex"])
    }

    func testANameWithNoLettersStillGetsAKey() {
        let preferences = Preferences(defaults: makeDefaults())
        XCTAssertEqual(preferences.addAccount(kind: .codex, name: "!!!", directory: "/x").id,
                       "codex.account")
    }

    func testAccountsSurviveARelaunch() {
        let defaults = makeDefaults()
        Preferences(defaults: defaults).addAccount(kind: .codex, name: "Gmail", directory: "/x")
        XCTAssertEqual(Preferences(defaults: defaults).accounts.map(\.id), ["claude", "codex", "codex.gmail"])
    }

    func testRenamingKeepsTheId() {
        let preferences = Preferences(defaults: makeDefaults())
        var claude = ConfiguredAccount.defaultClaude
        claude.name = "Team"
        preferences.updateAccount(claude)
        XCTAssertEqual(preferences.accounts.first?.id, "claude")
        XCTAssertEqual(preferences.accounts.first?.displayName, "Claude Team")
    }

    /// A removed account's "switched off" must not linger: re-adding it under
    /// the same name would come back dark for no visible reason.
    func testRemovingForgetsTheConnectionChoiceToo() {
        let preferences = Preferences(defaults: makeDefaults())
        let gmail = preferences.addAccount(kind: .codex, name: "Gmail", directory: "/x")
        preferences.setConnected(false, for: gmail.id)
        preferences.removeAccount(id: gmail.id)
        XCTAssertEqual(preferences.accounts.map(\.id), ["claude", "codex"])
        XCTAssertTrue(preferences.isConnected(gmail.id))
    }

    func testTheDefaultsCannotBeRemoved() {
        let preferences = Preferences(defaults: makeDefaults())
        preferences.removeAccount(id: "claude")
        XCTAssertEqual(preferences.accounts.map(\.id), ["claude", "codex"])
    }
}

/// Swapping the provider list in place, as adding or removing an account does.
@MainActor
final class ReplaceProvidersTests: XCTestCase {
    private final class Stub: UsageProvider {
        let id: String
        let displayName: String
        let glyph = ProviderGlyph.claude
        init(_ id: String) { self.id = id; displayName = id }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.5)])
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ReplaceProvidersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testARemovedProviderIsForgottenAndAnAddedOneFetched() async {
        let defaults = makeDefaults()
        let store = UsageStore(providers: [Stub("a"), Stub("b")],
                               archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(UsageArchive(defaults: defaults).load().keys.sorted(), ["a", "b"])

        store.replaceProviders([Stub("a"), Stub("c")])
        XCTAssertEqual(store.providers.map(\.id), ["a", "c"])
        XCTAssertEqual(store.snapshots.map(\.id), ["a", "c"])
        XCTAssertTrue(store.snapshots[0].hasReading, "the surviving provider keeps its reading")
        XCTAssertEqual(UsageArchive(defaults: defaults).load().keys.sorted(), ["a"],
                       "the removed provider's reading must not come back next launch")

        // The newcomer starts empty and is fetched without waiting for a tick.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(store.snapshots.first { $0.id == "c" }?.hasReading ?? false)
    }

    func testASwitchedOffProviderStaysOffAcrossTheSwap() {
        let store = UsageStore(providers: [Stub("a"), Stub("b")],
                               archive: UsageArchive(defaults: makeDefaults()),
                               disconnected: ["b"])
        store.replaceProviders([Stub("a"), Stub("b"), Stub("c")])
        XCTAssertEqual(store.snapshots.map(\.id), ["a", "c"])
    }
}

/// What the rest of the app keys on now that the id names an account.
final class ProviderKindTests: XCTestCase {
    func testTheSignInPromptFollowsTheToolNotTheId() {
        let snapshot = ProviderSnapshot(id: "codex.gmail", displayName: "Codex Gmail",
                                        glyph: .openai, fidelity: .official,
                                        status: .needsAuth, windows: [], kind: .codex)
        XCTAssertEqual(snapshot.statusMessage, "Sign in to Codex to read your usage")
    }

    /// Stubs and fixtures say nothing about their tool, and the wording still
    /// has to make sense.
    func testAnUnknownToolFallsBackToTheDisplayName() {
        let snapshot = ProviderSnapshot(id: "third", displayName: "Perplexity", glyph: .third,
                                        fidelity: .manual, status: .needsAuth, windows: [])
        XCTAssertEqual(snapshot.statusMessage, "Sign in to Perplexity to read your usage")
    }

    /// The account line under the title is real height, and the hover region
    /// is computed from the same budget the card draws with.
    func testTheAccountLineIsBudgeted() {
        XCTAssertGreaterThan(NotchLayout.cardHeight(windowCount: 1, accountLine: true),
                             NotchLayout.cardHeight(windowCount: 1))
        XCTAssertGreaterThanOrEqual(NotchLayout.maxCardHeight(sessionCap: NotchLayout.defaultSessionCap,
                                                              accountLine: true),
                                    NotchLayout.cardHeight(windowCount: NotchLayout.maxWindowCount,
                                                           sessionCount: NotchLayout.defaultSessionCap + 1,
                                                           accountLine: true))
    }

    /// The panel is sized once for the whole stack, so one card that names
    /// its account makes every card leave room for the line — and a stack
    /// with no such card pays nothing.
    @MainActor func testThePanelReservesTheLineOnlyWhenACardDrawsOne() {
        let model = NotchViewModel()
        model.edge = .right
        model.screenSize = CGSize(width: 1800, height: 1169)
        let bare = ProviderSnapshot(id: "a", displayName: "A", glyph: .claude,
                                    fidelity: .official, status: .ok, windows: [])
        model.snapshots = [bare]
        let without = model.maxCardHeight(cellCount: 1)
        var named = bare
        named.accountLabel = "me@example.com"
        model.snapshots = [named]
        XCTAssertGreaterThan(model.maxCardHeight(cellCount: 1), without)
    }
}

/// Two Claude accounts are two tokens with two rate-limit buckets.
final class BackoffPerAccountTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "BackoffPerAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testOneAccountsPenaltyDoesNotSilenceAnother() {
        let archive = UsageArchive(defaults: makeDefaults())
        archive.saveBackoffUntil(Date().addingTimeInterval(120), for: "claude.max")
        XCTAssertNotNil(archive.loadBackoffUntil(for: "claude.max"))
        XCTAssertNil(archive.loadBackoffUntil(for: "claude"))
    }

    /// The default account's penalty was stored under the old, unqualified
    /// key; an update mid-penalty must still wait it out.
    func testTheDefaultAccountReadsTheKeyItAlwaysHad() {
        let defaults = makeDefaults()
        defaults.set(Date().addingTimeInterval(120), forKey: "backoffUntil")
        XCTAssertNotNil(UsageArchive(defaults: defaults).loadBackoffUntil(for: "claude"))
    }
}

/// The archive carries the tool and the address now, and still reads what it
/// wrote before it did.
final class ArchiveAccountTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "ArchiveAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testKindAndAddressRoundTrip() throws {
        let defaults = makeDefaults()
        let reading = ProviderSnapshot(id: "codex.gmail", displayName: "Codex Gmail", glyph: .openai,
                                       fidelity: .official, status: .ok,
                                       windows: [LimitWindow(id: "w", label: "W", usedFraction: 0.2)],
                                       kind: .codex, accountLabel: "me@gmail.com")
        UsageArchive(defaults: defaults).save(["codex.gmail": (reading, Date())])
        let restored = try XCTUnwrap(UsageArchive(defaults: defaults).load()["codex.gmail"]).snapshot
        XCTAssertEqual(restored.kind, .codex)
        XCTAssertEqual(restored.accountLabel, "me@gmail.com")
    }

    /// An archive from before accounts has no `kind` — but its ids *were* the
    /// tools, so the tool is still known.
    func testAnOlderEntryInfersItsToolFromItsId() throws {
        let defaults = makeDefaults()
        let legacy = #"[{"id":"codex","displayName":"Codex","glyph":"openai","fidelity":"official","windows":[],"fetchedAt":0}]"#
        defaults.set(Data(legacy.utf8), forKey: "lastGoodReadings")
        let restored = try XCTUnwrap(UsageArchive(defaults: defaults).load()["codex"]).snapshot
        XCTAssertEqual(restored.kind, .codex)
        XCTAssertNil(restored.accountLabel)
    }
}
