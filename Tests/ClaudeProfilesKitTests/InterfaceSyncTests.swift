import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Interface sharing")
struct InterfaceSyncTests {
    static let origin = InterfaceSync.origin
    static let mainScope = "\(Sandbox.accountA)/org-a"
    static let workScope = "\(Sandbox.accountB)/org-b"

    /// Sandbox with a signed-in main app and profile, each with an empty Local Storage database.
    func sandbox() throws -> Sandbox {
        let box = try Sandbox()
        let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture/Local Storage", directoryHint: .isDirectory)
        for (dir, account) in [(box.main, Sandbox.accountA), (box.work, Sandbox.accountB)] {
            try FileManager.default.copyItem(at: fixture, to: dir.appending(path: "Local Storage", directoryHint: .isDirectory))
            try box.write(#"{"lastKnownAccountUuid":"\#(account)"}"#, to: dir.appending(path: "config.json"))
        }
        return box
    }

    func sidebar(_ state: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["state": state, "version": 1]), as: UTF8.self)
    }

    func sidebarState(_ items: [String: String]) throws -> [String: Any] {
        let text = try #require(items[InterfaceSync.sidebarKey])
        let store = try #require(InterfaceSync.object(text))
        return try #require(store["state"] as? [String: Any])
    }

    func items(_ dir: URL) throws -> [String: String] { try LocalStorage(dataDir: dir).items(origin: Self.origin) }

    func put(_ dir: URL, _ set: [String: String], remove: Set<String> = []) throws {
        try LocalStorage(dataDir: dir).update(origin: Self.origin, set: set, remove: remove)
    }

    @Test func profileGetsTheMainSidebarAndStateForItsOwnAccount() throws {
        let box = try sandbox()
        try put(box.main, [
            InterfaceSync.sidebarKey: try sidebar([
                "sidebarWidth": 242, "pinnedOrder": ["code:local_1"], "navPinnedIds": ["routines-chorus"],
                "collapsedGroups": ["project-done"], "lastSidebarScopeKey": Self.mainScope,
                "customGroupsByScope": [Self.mainScope: ["groups": ["g1"]], "old/scope": ["groups": ["stale"]]],
                "sidebarRowCountsByScope": [Self.mainScope: ["code.recents": 18]], "navHasCodeRoutinesByOrg": ["org-a": true],
            ]),
            "epitaxy-unread-v1": #"{"state":{"unreadIds":["local_1"]},"version":0}"#,
            "LSS-persisted.epitaxy-folder-permission-mode.\(Sandbox.accountA)": #"{"value":{"scratch:":"auto"},"tabId":"","timestamp":1}"#,
            "composer-draft:epitaxy-local_1": "unsent text",
            "__qk_hint_account_uuid": Sandbox.accountA,
        ])
        try put(box.work, [
            InterfaceSync.sidebarKey: try sidebar([
                "sidebarWidth": 288, "pinnedOrder": [], "navPinnedIds": NSNull(), "collapsedGroups": [],
                "lastSidebarScopeKey": Self.workScope, "customGroupsByScope": [:],
                "sidebarRowCountsByScope": [Self.workScope: ["code.recents": 50]], "navHasCodeRoutinesByOrg": [:],
            ]),
            "LSS-persisted.code-sessions-status-filter.\(Sandbox.accountB)": #"{"value":"all","tabId":"","timestamp":1}"#,
        ])

        let changed = try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work")

        let work = try items(box.work)
        let state = try sidebarState(work)
        #expect(state["sidebarWidth"] as? Int == 242)
        #expect(state["pinnedOrder"] as? [String] == ["code:local_1"])
        #expect(state["navPinnedIds"] as? [String] == ["routines-chorus"])
        #expect(state["collapsedGroups"] as? [String] == ["project-done"])
        #expect(state["lastSidebarScopeKey"] as? String == Self.workScope, "the profile's own account stays its own")
        #expect((state["customGroupsByScope"] as? [String: Any])?.keys.sorted() == [Self.workScope])
        #expect(((state["sidebarRowCountsByScope"] as? [String: Any])?[Self.workScope] as? [String: Int])?["code.recents"] == 50)
        #expect((state["navHasCodeRoutinesByOrg"] as? [String: Any])?.isEmpty == true)
        #expect(work["epitaxy-unread-v1"] == #"{"state":{"unreadIds":["local_1"]},"version":0}"#)
        #expect(work["LSS-persisted.epitaxy-folder-permission-mode.\(Sandbox.accountB)"] == #"{"value":{"scratch:":"auto"},"tabId":"","timestamp":1}"#)
        #expect(work["LSS-persisted.code-sessions-status-filter.\(Sandbox.accountB)"] == nil, "the main app shows the default filter")
        #expect(work["composer-draft:epitaxy-local_1"] == nil, "drafts are not copied")
        #expect(work["__qk_hint_account_uuid"] == nil, "account data is not copied")
        #expect(work["sidebarWidth"] == "240", "unrelated entries stay")
        #expect(changed == 4)
        #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0, "a second run has nothing to do")
    }

    @Test func aChangeMadeOnlyInTheProfileStays() throws {
        let box = try sandbox()
        let sync = InterfaceSync(paths: box.paths)
        let unread = "epitaxy-unread-v1"
        try put(box.main, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 242, "pinnedOrder": ["code:local_1"]]),
                           unread: #"{"state":{"unreadIds":["local_1"]}}"#])
        try put(box.work, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 288, "pinnedOrder": []])])
        try sync.run(into: box.work, profileID: "work")

        // The profile's window changes its width and reads the session; the main app pins another session.
        try put(box.work, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 300, "pinnedOrder": ["code:local_1"]]),
                           unread: #"{"state":{"unreadIds":[]}}"#])
        try put(box.main, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 242, "pinnedOrder": ["code:local_2"]])])
        try sync.run(into: box.work, profileID: "work")

        var state = try sidebarState(try items(box.work))
        #expect(state["sidebarWidth"] as? Int == 300)
        #expect(state["pinnedOrder"] as? [String] == ["code:local_2"])
        #expect(try items(box.work)[unread] == #"{"state":{"unreadIds":[]}}"#)

        // Once the main app changes the same setting too, the main app wins again.
        try put(box.main, [InterfaceSync.sidebarKey: try sidebar(["sidebarWidth": 250, "pinnedOrder": ["code:local_2"]])])
        try sync.run(into: box.work, profileID: "work")
        state = try sidebarState(try items(box.work))
        #expect(state["sidebarWidth"] as? Int == 250)
    }

    @Test func nothingIsWrittenBeforeSignInOrWhileTheWindowIsOpen() throws {
        let box = try sandbox()
        try put(box.main, ["epitaxy-unread-v1": #"{"state":{"unreadIds":["local_1"]}}"#])
        let config = box.work.appending(path: "config.json")
        try FileManager.default.removeItem(at: config)
        #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0, "not signed in yet")
        #expect(try items(box.work)["epitaxy-unread-v1"] == nil)

        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: config)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#,
                            LocalStorage(dataDir: box.work).dbDir.appending(path: "LOCK").path]
        let stdout = Pipe(), stdin = Pipe()
        holder.standardOutput = stdout
        holder.standardInput = stdin
        try holder.run()
        defer { stdin.fileHandleForWriting.closeFile(); holder.waitUntilExit() }
        _ = stdout.fileHandleForReading.availableData   // the holder's "locked" line

        #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0, "the window is open")
        #expect(try items(box.work)["epitaxy-unread-v1"] == nil)
    }

    // MARK: claude_desktop_config.json

    func prefs(_ dir: URL) throws -> [String: Any] {
        let config = try #require(SettingsSync.readJSON(dir.appending(path: InterfaceSync.desktopConfig)))
        return try #require((config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])
    }

    func writePrefs(_ box: Sandbox, _ dir: URL, _ prefs: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": prefs]])
        try box.write(String(decoding: data, as: UTF8.self), to: dir.appending(path: InterfaceSync.desktopConfig))
    }

    /// Claude reads these settings from `claude_desktop_config.json` before Local Storage.
    @Test func settingsClaudeReadsFirstFollowTheMainAppPerAccount() throws {
        let box = try sandbox()
        let (a, b) = (Sandbox.accountA, Sandbox.accountB)
        try writePrefs(box, box.main, ["dframe-local-slice": ["open": 1], "epitaxy-folder-permission-mode.\(a)": ["scratch:": "auto"],
                                       "somethingElse": true])
        try writePrefs(box, box.work, ["code-sessions-status-filter.\(b)": "all", "ownOnly": 2])
        let settings = SettingsSync(paths: box.paths), interface = InterfaceSync(paths: box.paths)

        // In the order opening a profile runs them.
        try settings.run(into: box.work)
        try interface.run(into: box.work, profileID: "work")

        var work = try prefs(box.work)
        #expect(work["code-sessions-status-filter.\(b)"] == nil, "the main app shows the default filter, so the profile does too")
        #expect((work["epitaxy-folder-permission-mode.\(b)"] as? [String: String]) == ["scratch:": "auto"])
        #expect(work["epitaxy-folder-permission-mode.\(a)"] == nil, "the main app's account isn't copied as is")
        #expect((work["dframe-local-slice"] as? [String: Int]) == ["open": 1])
        #expect(work["somethingElse"] as? Bool == true)
        #expect(work["ownOnly"] as? Int == 2)
        #expect(try settings.run(into: box.work) == 0 && interface.run(into: box.work, profileID: "work") == 0,
                "a second run has nothing to do")

        // A change made only in the profile's window stays, through both.
        var changed = work
        changed["dframe-local-slice"] = ["open": 2]
        try writePrefs(box, box.work, changed)
        try settings.run(into: box.work)
        try interface.run(into: box.work, profileID: "work")
        work = try prefs(box.work)
        #expect((work["dframe-local-slice"] as? [String: Int]) == ["open": 2])
    }

    // MARK: IndexedDB

    /// The serialized form of a one-byte string as Chromium stores it: Blink's header with its trailer offset,
    /// V8's header, then the string.
    static func serialized(_ text: String) -> [UInt8] {
        var length = ByteWriter()
        length.appendVarint64(UInt64(text.utf8.count))
        return [0xFF, 0x15, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 0x0F, 0x22] + length.bytes + Array(text.utf8)
    }

    /// Claude's key-value IndexedDB database with `records` (key → version, JSON text), built on a copy of the
    /// Local Storage fixture: any LevelDB database will do, the two kinds of keys never collide.
    @discardableResult
    func makePinStore(_ dataDir: URL, records: [String: (UInt64, String)], databaseID: UInt64 = 1,
                      blobs: Set<String> = [], dataVersion: UInt64 = 0x10_0000_0015,
                      extra: (_ database: UInt64, _ objectStore: UInt64) -> [([UInt8], [UInt8])] = { _, _ in [] }) throws -> IndexedDBStore {
        let store = IndexedDBStore(dataDir: dataDir, database: InterfaceSync.pinDatabase, objectStore: InterfaceSync.pinObjectStore)
        let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture/Local Storage/leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store.dbDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: store.dbDir)
        let db = databaseID, os: UInt64 = 1
        var put: [([UInt8], [UInt8])] = [
            (IDBKey.prefix(0, 0, 0) + [IDBKey.dataVersionType], IDBKey.encodeInt(dataVersion)),
            (IDBKey.prefix(0, 0, 0) + [201] + IDBKey.stringWithLength(store.origin) + IDBKey.stringWithLength(store.database), IDBKey.encodeInt(db)),
            (IDBKey.prefix(db, 0, 0) + [200] + IDBKey.stringWithLength(store.objectStore), IDBKey.encodeInt(os)),
            (IDBKey.objectStoreMetadata(db, os, .name), IDBKey.utf16BE(store.objectStore)),
            (IDBKey.objectStoreMetadata(db, os, .lastVersion), IDBKey.encodeInt(records.values.map(\.0).max() ?? 0)),
        ]
        for (key, (version, json)) in records {
            var record = ByteWriter()
            record.appendVarint64(version)
            put.append((IDBKey.prefix(db, os, IDBKey.dataIndex) + IDBKey.string(key), record.bytes + Self.serialized(json)))
            put.append((IDBKey.prefix(db, os, IDBKey.existsIndex) + IDBKey.string(key), IDBKey.encodeInt(version)))
        }
        for key in blobs { put.append((IDBKey.prefix(db, os, IDBKey.blobIndex) + IDBKey.string(key), [0])) }
        put += extra(db, os)
        try store.store.append(put: put, delete: [])
        return store
    }

    @Test func starredSessionsAndOpenSectionsFollowTheMainApp() throws {
        let box = try sandbox()
        let starred = "store:pin-state:dframe-starred-code", groups = "store:pin-state:dframe-session-groups"
        let mainStarred = #"{"state":{"starredIds":["local_1"]},"version":0}"#
        let mainGroups = #"{"state":{"expandedIds":["routines"]},"version":0}"#
        try makePinStore(box.main, records: [starred: (7, mainStarred), groups: (8, mainGroups)], databaseID: 5)
        let work = try makePinStore(box.work, records: [groups: (2, #"{"state":{"expandedIds":[]},"version":0}"#),
                                                        "unrelated": (3, "own")], databaseID: 2)
        let sync = InterfaceSync(paths: box.paths)

        #expect(try sync.run(into: box.work, profileID: "work") == 2)

        let snapshot = try #require(try work.read())
        #expect(snapshot.records[starred]?.string == mainStarred)
        #expect(snapshot.records[groups]?.string == mainGroups)
        #expect(snapshot.records["unrelated"]?.string == "own")
        let version = try #require(snapshot.records[starred]?.version)
        #expect(version > 3 && snapshot.lastVersion >= version, "new records get versions the store hasn't used")
        let exists = IDBKey.prefix(2, 1, IDBKey.existsIndex) + IDBKey.string(starred)
        #expect(try work.store.liveEntries()[exists] == IDBKey.encodeInt(version))
        let backups = try FileManager.default.subpathsOfDirectory(atPath: box.paths.backupsDir.path)
        #expect(backups.contains { $0.hasSuffix("Interface/work-IndexedDB.json") }, "replaced values are kept")
        #expect(try sync.run(into: box.work, profileID: "work") == 0, "a second run has nothing to do")
        let logs = try FileManager.default.contentsOfDirectory(at: work.dbDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }.max { $0.lastPathComponent < $1.lastPathComponent }
        let permissions = try FileManager.default.attributesOfItem(atPath: try #require(logs).path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "private to the user, like Chromium's own files")

        // Starring a session only in the profile's window stays.
        let own = #"{"state":{"starredIds":["local_2"]},"version":0}"#
        try work.write([starred: Self.serialized(own)], into: snapshot)
        #expect(try sync.run(into: box.work, profileID: "work") == 0)
        #expect(try work.read()?.records[starred]?.string == own)
    }

    @Test func pinRecordsWithBlobsOrAnotherVersionAreLeftAlone() throws {
        let box = try sandbox()
        let starred = "store:pin-state:dframe-starred-code", groups = "store:pin-state:dframe-session-groups"
        try makePinStore(box.main, records: [starred: (1, #"{"state":{"starredIds":["a"]},"version":1}"#),
                                             groups: (2, #"{"state":{"expandedIds":["b"]},"version":0}"#)])
        let work = try makePinStore(box.work, records: [starred: (1, #"{"state":{"starredIds":[]},"version":0}"#),
                                                        groups: (2, #"{"state":{"expandedIds":[]},"version":0}"#)], blobs: [groups])
        #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0)
        let records = try #require(try work.read()?.records)
        #expect(records[starred]?.string == #"{"state":{"starredIds":[]},"version":0}"#)
        #expect(records[groups]?.string == #"{"state":{"expandedIds":[]},"version":0}"#)
    }

    /// A write adds records the way `put` does and nothing else, so a store that also keeps indexes or a key
    /// generator, or data in another format, is never written.
    @Test func storesAWriteWouldNotKeepConsistentAreLeftAlone() throws {
        let starred = "store:pin-state:dframe-starred-code"
        let own = #"{"state":{"starredIds":[]},"version":0}"#
        let index: (UInt64, UInt64) -> [([UInt8], [UInt8])] = { db, os in
            var ids = ByteWriter()
            ids.appendVarint64(os)
            ids.appendVarint64(30)
            return [(IDBKey.prefix(db, 0, 0) + [IDBKey.indexMetadataType] + ids.bytes + [0], IDBKey.utf16BE("byDate"))]
        }
        let keyGenerator: (UInt64, UInt64) -> [([UInt8], [UInt8])] = { db, os in [(IDBKey.objectStoreMetadata(db, os, .autoIncrement), [1])] }
        for (name, extra, dataVersion) in [("index", index, UInt64(0x10_0000_0015)),
                                           ("key generator", keyGenerator, 0x10_0000_0015),
                                           ("data version", { _, _ in [] }, 0x10_0000_0014)] {
            let box = try sandbox()
            try makePinStore(box.main, records: [starred: (1, #"{"state":{"starredIds":["a"]},"version":0}"#)])
            let work = try makePinStore(box.work, records: [starred: (1, own)], dataVersion: dataVersion, extra: extra)
            #expect(try InterfaceSync(paths: box.paths).run(into: box.work, profileID: "work") == 0, "\(name)")
            let entries = try work.store.liveEntries()
            #expect(entries[IDBKey.prefix(1, 1, IDBKey.dataIndex) + IDBKey.string(starred)] == [1] + Self.serialized(own), "\(name)")
        }
    }

    /// What was merged before a failure is remembered, so the next run doesn't take it for a change in the profile.
    @Test func placesMergedBeforeAFailureAreRemembered() throws {
        let box = try sandbox()
        let starred = "store:pin-state:dframe-starred-code"
        try writePrefs(box, box.main, ["dframe-local-slice": ["open": 1]])
        try writePrefs(box, box.work, ["ownOnly": 2])
        try makePinStore(box.main, records: [starred: (1, #"{"state":{"starredIds":["a"]},"version":0}"#)])
        try makePinStore(box.work, records: [starred: (1, #"{"state":{"starredIds":[]},"version":0}"#)])
        let now = Date()
        let blocked = Backup(paths: box.paths, now: now).dayDir.appending(path: "Interface")
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: blocked)   // a file where the backup of the replaced pins would go
        let sync = InterfaceSync(paths: box.paths)

        #expect(throws: (any Error).self) { try sync.run(into: box.work, profileID: "work", now: now) }

        let state = InterfaceSync.readState(sync.stateFile(for: "work"))
        #expect(state["prefs:dframe-local-slice"] != nil)
        #expect(state["idb:" + starred] == nil)
        #expect((try prefs(box.work)["dframe-local-slice"] as? [String: Int]) == ["open": 1])
    }

    @Test func readsTheStringsChromiumSerializes() {
        #expect(IDBValue.string(in: Self.serialized("hello")) == "hello")
        // Two-byte string, after V8's padding byte: "Яb" in UTF-16LE.
        #expect(IDBValue.string(in: [0xFF, 0x0F, 0x00, 0x63, 0x04, 0x2F, 0x04, 0x62, 0x00]) == "Яb")
        #expect(IDBValue.string(in: [0xFF, 0x0F, 0x53, 0x02, 0xD0, 0xAF]) == "Я")
        #expect(IDBValue.string(in: Self.serialized("hello") + [0x00]) == nil, "anything after the string means another shape")
        #expect(IDBValue.string(in: [0xFF, 0x0F, 0x6F, 0x7B, 0x00]) == nil, "an object isn't a string")
    }
}
