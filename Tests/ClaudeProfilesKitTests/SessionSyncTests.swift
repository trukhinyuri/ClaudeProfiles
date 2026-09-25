import Foundation
import Testing
@testable import ClaudeProfilesKit

/// A throwaway home directory with a main data dir and one profile.
struct Sandbox {
    let root: URL
    let paths: Paths
    var main: URL { paths.mainDataDir }
    var work: URL { paths.dataDir(for: "work") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "cu-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = Paths(home: root, claudeApp: root.appending(path: "Applications/Claude.app"))
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    static let accountA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    static let accountB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    @discardableResult
    func pair(_ dataDir: URL, account: String, org: String = "org-1") throws -> URL {
        let dir = dataDir.appending(path: "claude-code-sessions/\(account)/\(org)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    func sync(propagateDeletions: Bool = false) throws -> SessionSync.Report {
        try SessionSync(paths: paths, dataDirs: [main, work]).run(propagateDeletions: propagateDeletions)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Suite("Session sharing")
struct SessionSyncTests {
    @Test func copiesCardsToEveryAccountOfEveryProfile() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"one"}"#, to: a.appending(path: "local_1.json"))
        try box.write(#"{"title":"two"}"#, to: b.appending(path: "local_2.json"))

        let report = try box.sync()

        #expect(report.pairs == 2)
        #expect(report.cardsWritten == 2)
        #expect(box.read(b.appending(path: "local_1.json")) == #"{"title":"one"}"#)
        #expect(box.read(a.appending(path: "local_2.json")) == #"{"title":"two"}"#)
        #expect(try box.sync().changes == 0, "a second run has nothing to do")
    }

    @Test func newestCardWinsAndOldCopyIsBackedUp() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let old = Date().addingTimeInterval(-3600)
        try box.write("old", to: a.appending(path: "local_1.json"), modified: old)
        try box.write("new", to: b.appending(path: "local_1.json"), modified: Date())

        let report = try box.sync()

        #expect(box.read(a.appending(path: "local_1.json")) == "new")
        #expect(report.backedUp == 1)
    }

    @Test func deletedSessionsAreNeverResurrected() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write("card", to: b.appending(path: "local_x.json"))
        try box.write("", to: a.appending(path: "deleted_x"))

        let additive = try box.sync(propagateDeletions: false)
        #expect(additive.cardsWritten == 0)
        #expect(!box.exists(a.appending(path: "local_x.json")))
        #expect(box.exists(b.appending(path: "local_x.json")), "no removals while Claude may be running")

        let full = try box.sync(propagateDeletions: true)
        #expect(full.cardsRemoved == 1)
        #expect(full.tombstonesWritten == 1)
        #expect(!box.exists(b.appending(path: "local_x.json")))
        #expect(box.exists(b.appending(path: "deleted_x")))
    }

    @Test func archivedSessionsAreMerged() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"v":1,"archived":["s1"]}"#, to: a.appending(path: "archived-sessions.idx"))
        try box.write(#"{"v":1,"archived":["s2"]}"#, to: b.appending(path: "archived-sessions.idx"))

        _ = try box.sync()

        for dir in [a, b] {
            let data = try Data(contentsOf: dir.appending(path: "archived-sessions.idx"))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["archived"] as? [String] == ["s1", "s2"])
        }
    }

    /// A "No folder" session keeps its scratch folder in the data directory of the window that started it; each
    /// window's copy has to name that window's data directory for Claude to show it as one.
    @Test func scratchSessionsNameEachWindowsOwnDataDirectory() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let scratch = { (dir: URL) in dir.path + "/scratch-workspaces/\(Sandbox.accountA)/org-1/abc" }
        let card = { (origin: URL) in #"{"cwd":"\#(scratch(box.main))","originCwd":"\#(scratch(origin))","title":"t"}"# }
        let modified = Date().addingTimeInterval(-600)
        try box.write(card(box.main), to: a.appending(path: "local_1.json"), modified: modified)
        // Copied before this was handled: the same card, with the same date, in the profile.
        try box.write(card(box.main), to: b.appending(path: "local_1.json"), modified: modified)
        try box.write(card(box.work), to: b.appending(path: "local_2.json"), modified: modified)

        let report = try box.sync()

        #expect(box.read(a.appending(path: "local_1.json")) == card(box.main))
        #expect(box.read(b.appending(path: "local_1.json")) == card(box.work), "cwd stays, originCwd moves")
        #expect(box.read(a.appending(path: "local_2.json")) == card(box.main))
        #expect(report.cardsWritten == 2)
        #expect(SyncFolders.modificationDate(b.appending(path: "local_1.json")).map { abs($0.timeIntervalSince(modified)) < 1 } == true,
                "the card's date isn't changed, so it doesn't look newer than it is")
        #expect(try box.sync().changes == 0, "a second run has nothing to do")
    }

    @Test func ignoresSymlinksAndForeignFolders() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        try box.write("card", to: a.appending(path: "local_1.json"))
        let sessions = box.work.appending(path: "claude-code-sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions.appending(path: Sandbox.accountB), withDestinationURL: a)
        try FileManager.default.createDirectory(at: sessions.appending(path: "not-an-account/org"), withIntermediateDirectories: true)

        #expect(try box.sync().pairs == 1)
    }
}

@Suite("Backups")
struct BackupTests {
    @Test func backupsOlderThanAWeekArePruned() throws {
        let box = try Sandbox()
        let stale = box.paths.backupsDir.appending(path: "2001-01-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let fresh = Backup(paths: box.paths, now: Date()).dayDir
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)

        var discarded: [URL] = []
        var backup = Backup(paths: box.paths, now: Date())
        backup.discard = { discarded.append($0); try FileManager.default.removeItem(at: $0) }
        let moved = backup.prune()

        #expect(moved == 1)
        #expect(discarded.map(\.lastPathComponent) == ["2001-01-01"])
        #expect(!box.exists(stale))
        #expect(box.exists(fresh))
    }
}

@Suite("Safety")
struct SafetyTests {
    @Test func everyRemovalIsBackedUp() throws {
        let box = try Sandbox()
        let backup = Backup(paths: box.paths, now: Date())
        let file = box.main.appending(path: "local_1.json")
        try box.write("v1", to: file)
        #expect(try backup.save(file, everyTime: true))
        try box.write("v2", to: file)
        #expect(try backup.save(file, everyTime: true), "a second removal the same day gets its own copy")
        #expect(try !backup.save(file), "overwrites keep only the first copy of the day")
    }

    @Test func damagedRegistryIsNeverOverwritten() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.paths.stateDir, withIntermediateDirectories: true)
        try box.write("{ not json", to: box.paths.registryFile)
        let manager = ProfileManager(paths: box.paths)
        #expect(manager.registryError != nil)
        #expect(throws: (any Error).self) { try ProfileRegistry(paths: box.paths).load() }
        #expect(box.read(box.paths.registryFile) == "{ not json")
    }

    @Test func versionIsReadFreshFromDisk() throws {
        let box = try Sandbox()
        let contents = box.paths.claudeApp.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appending(path: "Info.plist")
        for version in ["1.0", "2.0"] {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": version], format: .xml, options: 0).write(to: plist)
            #expect(ProfileManager.version(of: box.paths.claudeApp) == version)
        }
    }

    @Test func concurrentSyncIsSkippedNotRaced() throws {
        let box = try Sandbox()
        let manager = ProfileManager(paths: box.paths)
        let inner = try FileLock.withLock(box.paths.stateDir.appending(path: "sync.lock"), blocking: false) {
            try manager.syncSessions()
        }
        #expect(inner == .some(nil), "a sync started while another holds the lock returns nil")
        #expect(try manager.syncSessions() != nil)
    }
}

@Suite("Settings sharing")
struct SettingsSyncTests {
    @Test func copiesExtensionsAndMergesConfigWithoutTouchingSignIn() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        try fm.createDirectory(at: box.main.appending(path: "Claude Extensions/ext"), withIntermediateDirectories: true)
        try box.write("{}", to: box.main.appending(path: "Claude Extensions/ext/manifest.json"))
        try box.write(#"{"mcpServers":{"a":{"command":"x"}},"preferences":{"keepAwakeEnabled":true,"sidebarMode":"code"}}"#,
                      to: box.main.appending(path: "claude_desktop_config.json"))
        try box.write(#"{"mcpServers":{"old":{}},"preferences":{"sidebarMode":"chat","ownOnly":1}}"#,
                      to: box.work.appending(path: "claude_desktop_config.json"))
        try box.write(#"{"token":"main"}"#, to: box.main.appending(path: "config.json"))
        try box.write(#"{"token":"work"}"#, to: box.work.appending(path: "config.json"))

        let sync = SettingsSync(paths: box.paths)
        #expect(try sync.run(into: box.work) == 2)

        #expect(box.exists(box.work.appending(path: "Claude Extensions/ext/manifest.json")))
        let config = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json")))
        #expect((config["mcpServers"] as? [String: Any])?.keys.sorted() == ["a"], "MCP servers mirror the main app")
        let prefs = try #require(config["preferences"] as? [String: Any])
        #expect(prefs["sidebarMode"] as? String == "code")
        #expect(prefs["keepAwakeEnabled"] as? Bool == true)
        #expect(prefs["ownOnly"] as? Int == 1, "settings only the profile has are kept")
        #expect(box.read(box.work.appending(path: "config.json")) == #"{"token":"work"}"#, "sign-in is never copied")
        #expect(try sync.run(into: box.work) == 0, "a second run has nothing to do")
    }

    @Test func scheduledTasksStayOffInProfiles() throws {
        let box = try Sandbox()
        try box.write(#"{"preferences":{"ccdScheduledTasksEnabled":true,"coworkScheduledTasksEnabled":true,"wakeSchedulerEnabled":true}}"#,
                      to: box.main.appending(path: "claude_desktop_config.json"))
        try SettingsSync(paths: box.paths).run(into: box.work)
        let prefs = try #require(SettingsSync.readJSON(box.work.appending(path: "claude_desktop_config.json"))?["preferences"] as? [String: Any])
        for key in SettingsSync.schedulerPreferences {
            #expect(prefs[key] as? Bool == false, "only the main app runs scheduled tasks: \(key)")
        }
    }

    @Test func toolTogglesFollowTheProfilesAccount() throws {
        let box = try Sandbox()
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountA)"}"#, to: box.main.appending(path: "config.json"))
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: box.work.appending(path: "config.json"))
        try box.write(#"{"owners":{"\#(Sandbox.accountA)":{"github":{"push":false}}}}"#,
                      to: box.main.appending(path: "mcp-user-tool-toggles.json"))
        try SettingsSync(paths: box.paths).run(into: box.work)
        let owners = try #require(SettingsSync.readJSON(box.work.appending(path: "mcp-user-tool-toggles.json"))?["owners"] as? [String: Any])
        let chosen = try #require(owners[Sandbox.accountB] as? [String: Any])
        #expect((chosen["github"] as? [String: Any])?["push"] as? Bool == false)
    }

    @Test func appearanceIsCopiedButSignInIsNot() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        try box.write(#"{"userThemeMode":"dark","locale":"en-US","oauth:tokenCache":"main-secret","lastKnownAccountUuid":"\#(Sandbox.accountA)"}"#,
                      to: box.main.appending(path: "config.json"))
        let own = box.work.appending(path: "config.json")
        try box.write(#"{"userThemeMode":"light","oauth:tokenCache":"work-secret","lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: own)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: own.path)

        try SettingsSync(paths: box.paths).run(into: box.work)

        let config = try #require(SettingsSync.readJSON(own))
        #expect(config["userThemeMode"] as? String == "dark")
        #expect(config["locale"] as? String == "en-US")
        #expect(config["oauth:tokenCache"] as? String == "work-secret")
        #expect(config["lastKnownAccountUuid"] as? String == Sandbox.accountB)
        #expect((try fm.attributesOfItem(atPath: own.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let backedUp = (try? fm.subpathsOfDirectory(atPath: box.paths.backupsDir.path)) ?? []
        #expect(!backedUp.contains { $0.hasSuffix("/config.json") }, "the file holding sign-in is never copied into backups")
    }

    @Test func finishedClaudeCodeBuildsAreCloned() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let builds = box.main.appending(path: "claude-code")
        try fm.createDirectory(at: builds.appending(path: "2.0.0/claude.app"), withIntermediateDirectories: true)
        try box.write("sha", to: builds.appending(path: "2.0.0/.verified"))
        try fm.createDirectory(at: builds.appending(path: "2.1.0/claude.app"), withIntermediateDirectories: true)

        try SettingsSync(paths: box.paths).run(into: box.work)

        let copied = try fm.contentsOfDirectory(atPath: box.work.appending(path: "claude-code").path)
        #expect(copied == ["2.0.0"], "an unfinished download (no .verified) is left alone")
        #expect(box.read(box.work.appending(path: "claude-code/2.0.0/.verified")) == "sha")
    }

    @Test func profileNeverSignedInGetsNoConfigFile() throws {
        let box = try Sandbox()
        try box.write(#"{"userThemeMode":"dark","oauth:tokenCache":"main-secret"}"#, to: box.main.appending(path: "config.json"))
        try SettingsSync(paths: box.paths).run(into: box.work)
        #expect(!box.exists(box.work.appending(path: "config.json")))
    }
}

@Suite("Organizations")
struct OrganizationTests {
    @Test func organizationIsTheMostRecentlyUsedOne() throws {
        let box = try Sandbox()
        let older = "11111111-1111-1111-1111-111111111111", newer = "22222222-2222-2222-2222-222222222222"
        let fm = FileManager.default
        try box.pair(box.work, account: Sandbox.accountB, org: older)
        try box.pair(box.work, account: Sandbox.accountB, org: newer)
        try box.pair(box.work, account: Sandbox.accountB, org: "not-an-org")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                             ofItemAtPath: box.work.appending(path: "claude-code-sessions/\(Sandbox.accountB)/\(older)").path)
        #expect(DesktopData.organizationID(in: box.work, accountID: Sandbox.accountB) == newer)
        #expect(DesktopData.organizationID(in: box.work, accountID: Sandbox.accountA) == nil)
    }

    @Test func newlySignedInProfileGetsASessionFolder() throws {
        let box = try Sandbox()
        let org = "33333333-3333-3333-3333-333333333333"
        try ProfileRegistry(paths: box.paths).save([Profile(id: "work", label: "WORK", email: "w@example.com", color: "#1971C2")])
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: box.work.appending(path: "config.json"))
        try FileManager.default.createDirectory(at: box.work.appending(path: "local-agent-mode-sessions/\(Sandbox.accountB)/\(org)"),
                                                withIntermediateDirectories: true)
        let main = try box.pair(box.main, account: Sandbox.accountA)
        try box.write(#"{"title":"one"}"#, to: main.appending(path: "local_1.json"))

        _ = try ProfileManager(paths: box.paths).syncSessions()

        let folder = box.work.appending(path: "claude-code-sessions/\(Sandbox.accountB)/\(org)")
        #expect(box.read(folder.appending(path: "local_1.json")) == #"{"title":"one"}"#, "shared before the window restarts")
    }

    @Test func organizationIsComparedAcrossSessionKinds() throws {
        let box = try Sandbox()
        let older = "11111111-1111-1111-1111-111111111111", newer = "22222222-2222-2222-2222-222222222222"
        let fm = FileManager.default
        try box.pair(box.work, account: Sandbox.accountB, org: older)
        let cowork = box.work.appending(path: "local-agent-mode-sessions/\(Sandbox.accountB)/\(newer)")
        try fm.createDirectory(at: cowork, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                             ofItemAtPath: box.work.appending(path: "claude-code-sessions/\(Sandbox.accountB)/\(older)").path)
        #expect(DesktopData.organizationID(in: box.work, accountID: Sandbox.accountB) == newer)
    }
}
