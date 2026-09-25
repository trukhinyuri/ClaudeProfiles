import Foundation
import Testing
@testable import ClaudeProfilesKit

extension Sandbox {
    var lab: URL { paths.dataDir(for: "lab") }

    @discardableResult
    func coworkPair(_ dataDir: URL, account: String, org: String = "org-1") throws -> URL {
        let dir = dataDir.appending(path: "local-agent-mode-sessions/\(account)/\(org)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func coworkSync(dataDirs: [URL]? = nil, propagateDeletions: Bool = false, now: Date = Date()) throws -> CoworkSync.Report {
        try CoworkSync(paths: paths, dataDirs: dataDirs ?? [main, work]).run(propagateDeletions: propagateDeletions, now: now)
    }
}

@Suite("Cowork sharing")
struct CoworkSyncTests {
    @Test func sharesCardsBothWays() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"one"}"#, to: a.appending(path: "local_1.json"))
        try box.write(#"{"title":"two"}"#, to: b.appending(path: "local_2.json"))

        let report = try box.coworkSync()

        #expect(report.pairs == 2)
        #expect(report.cardsWritten == 2)
        #expect(box.read(b.appending(path: "local_1.json")) == #"{"title":"one"}"#)
        #expect(box.read(a.appending(path: "local_2.json")) == #"{"title":"two"}"#)
        #expect(try box.coworkSync().changes == 0, "a second run has nothing to do")
    }

    @Test func neverCopiesScheduledTasksOrWorkingFolders() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        try box.write(#"{"title":"one"}"#, to: a.appending(path: "local_1.json"))
        try FileManager.default.createDirectory(at: a.appending(path: "local_1", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try box.write("[]", to: a.appending(path: "scheduled-tasks.json"))
        try box.write("{}", to: a.appending(path: "cowork-x-cache.json"))
        try box.write("{}", to: a.appending(path: "remote-session-spaces.json"))
        try FileManager.default.createDirectory(at: a.appending(path: "rpm", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a.appending(path: "a1b2c3d4", directoryHint: .isDirectory), withIntermediateDirectories: true)

        _ = try box.coworkSync()

        let copied = Set((try FileManager.default.contentsOfDirectory(at: b, includingPropertiesForKeys: nil)).map(\.lastPathComponent))
        #expect(copied == ["local_1.json"])
    }

    @Test func deletionWhileClaudeRunsIsNotResurrected() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        try box.write("card", to: a.appending(path: "local_x.json"))
        try box.write("card", to: b.appending(path: "local_x.json"))
        _ = try box.coworkSync()   // establishes the baseline: both folders have the card

        try FileManager.default.removeItem(at: a.appending(path: "local_x.json"))   // deleted in a's window
        let report = try box.coworkSync(propagateDeletions: false)

        #expect(!box.exists(a.appending(path: "local_x.json")), "not copied back while a window may be open")
        #expect(box.exists(b.appending(path: "local_x.json")), "no removals while Claude may be running")
        #expect(report.cardsRemoved == 0)

        // The deletion keeps being remembered on a later run too, not just the one right after it happened.
        let again = try box.coworkSync(propagateDeletions: false)
        #expect(!box.exists(a.appending(path: "local_x.json")))
        #expect(again.cardsWritten == 0)
    }

    @Test func deletionIsPropagatedWhenNoClaudeRuns() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        try box.write("card", to: a.appending(path: "local_x.json"))
        try box.write("card", to: b.appending(path: "local_x.json"))
        _ = try box.coworkSync()

        try FileManager.default.removeItem(at: a.appending(path: "local_x.json"))
        let report = try box.coworkSync(propagateDeletions: true)

        #expect(report.cardsRemoved == 1)
        #expect(!box.exists(b.appending(path: "local_x.json")))
    }

    @Test func newProfileFolderIsFilledNotTreatedAsDeletion() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        try box.write("card", to: a.appending(path: "local_x.json"))
        try box.write("card", to: b.appending(path: "local_x.json"))
        _ = try box.coworkSync()   // baseline with only main and work

        let c = try box.coworkPair(box.lab, account: Sandbox.accountA, org: "org-2")   // a brand new profile folder
        let report = try box.coworkSync(dataDirs: [box.main, box.work, box.lab], propagateDeletions: true)

        #expect(box.read(c.appending(path: "local_x.json")) == "card", "filled, not read as a's or b's deletion")
        #expect(report.cardsRemoved == 0)
    }

    @Test func editedCardAfterDeletionElsewhereSurvives() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        let t0 = Date()
        try box.write("v1", to: a.appending(path: "local_x.json"), modified: t0)
        try box.write("v1", to: b.appending(path: "local_x.json"), modified: t0)
        _ = try box.coworkSync(now: t0.addingTimeInterval(10))   // baseline: both folders have the card

        try FileManager.default.removeItem(at: a.appending(path: "local_x.json"))   // deleted in a
        _ = try box.coworkSync(propagateDeletions: false, now: t0.addingTimeInterval(20))
        #expect(!box.exists(a.appending(path: "local_x.json")))

        // b's copy is touched after the run that noticed the deletion.
        try box.write("v2", to: b.appending(path: "local_x.json"), modified: t0.addingTimeInterval(30))
        let report = try box.coworkSync(propagateDeletions: true, now: t0.addingTimeInterval(40))

        #expect(box.read(a.appending(path: "local_x.json")) == "v2", "the edit outlives the deletion seen in a")
        #expect(report.cardsRemoved == 0)
    }

    @Test func removedProfilesSessionsLeaveOtherWindows() throws {
        let box = try Sandbox()
        let a = try box.coworkPair(box.main, account: Sandbox.accountA)
        let b = try box.coworkPair(box.work, account: Sandbox.accountB)
        let fromWork = #"{"cwd":"\#(b.path)/local_w"}"#, fromMain = #"{"cwd":"\#(a.path)/local_m"}"#
        for dir in [a, b] {
            try box.write(fromWork, to: dir.appending(path: "local_w.json"))
            try box.write(fromMain, to: dir.appending(path: "local_m.json"))
        }

        let removed = try CoworkSync(paths: box.paths, dataDirs: [box.main]).removeCards(workingIn: box.work)

        #expect(removed == 1)
        #expect(!box.exists(a.appending(path: "local_w.json")), "its files went to the Trash with the profile")
        #expect(box.read(a.appending(path: "local_m.json")) == fromMain)
        let backedUp = try FileManager.default.subpathsOfDirectory(atPath: box.paths.backupsDir.path)
        #expect(backedUp.contains { $0.hasSuffix("local_w.json") })
    }
}
