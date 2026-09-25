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
}
