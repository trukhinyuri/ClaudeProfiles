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
