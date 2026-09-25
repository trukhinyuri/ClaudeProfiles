import AppKit
import Foundation
import Testing
@testable import ClaudeUnlimitedKit

@Suite("Profiles")
struct ProfileTests {
    @Test(arguments: [
        ("jane.doe@acme.com", "JANE"),
        ("x@y.io", "X"),
        ("verylongname@corp.com", "VERYLONG"),
    ])
    func suggestsLabelFromEmail(email: String, label: String) {
        #expect(Profile.suggestedLabel(for: email, taken: []) == label)
    }

    @Test func suggestedLabelAvoidsTakenOnes() {
        #expect(Profile.suggestedLabel(for: "jane@a.com", taken: ["JANE"]) == "JANE2")
        #expect(Profile.suggestedLabel(for: "jane@a.com", taken: ["jane", "JANE2"]) == "JANE3")
    }

    @Test func slugIsFilesystemSafe() {
        #expect(Profile.slug(for: "WORK") == "work")
        #expect(Profile.slug(for: "a b/c") == "a-b-c")
        #expect(Profile.slug(for: "ЛАБ") == "profile")
    }

    @Test func validatesInput() {
        #expect(Profile.isValidLabel("TEAM-2"))
        #expect(!Profile.isValidLabel(""))
        #expect(!Profile.isValidLabel("WAY-TOO-LONG"))
        #expect(!Profile.isValidLabel("a b"))
        #expect(Profile.isValidEmail("a@b.co"))
        #expect(!Profile.isValidEmail("a@b"))
        #expect(!Profile.isValidEmail("a b@c.com"))
    }

    @Test func registryRoundTrips() throws {
        let box = try Sandbox()
        let registry = ProfileRegistry(paths: box.paths)
        #expect(try registry.load().isEmpty)
        let profile = Profile(id: "work", label: "WORK", email: "a@b.co", color: "#1971C2",
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try registry.save([profile])
        #expect(try registry.load() == [profile])
    }

    @Test func unexpectedAccountIsCaseInsensitive() {
        let profile = Profile(id: "w", label: "W", email: "Jane@Acme.com", color: "#000000")
        var status = ProfileStatus(profile: profile, accountID: "id", email: "jane@acme.com", usage: nil, isRunning: false)
        #expect(!status.isUnexpectedAccount)
        status.email = "other@acme.com"
        #expect(status.isUnexpectedAccount)
    }
}

@Suite("Reading Claude Desktop data")
struct DesktopDataTests {
    @Test func readsOnlyTheAccountIDFromConfig() throws {
        let box = try Sandbox()
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountA)","oauth:tokenCache":"secret"}"#,
                      to: box.main.appending(path: "config.json"))
        #expect(DesktopData.accountID(in: box.main) == Sandbox.accountA)
        #expect(DesktopData.accountID(in: box.work) == nil)
    }

    @Test func readsLatestUsageSample() throws {
        let box = try Sandbox()
        try box.write(#"{"version":1,"samples":[{"t":1790338178961,"u":{"fh":20,"sd":79}},{"t":1790337278917,"u":{"fh":15,"sd":77}}]}"#,
                      to: box.main.appending(path: "plan-usage-history.json"))
        let usage = try #require(DesktopData.usage(in: box.main))
        #expect(usage.fiveHour == 20)
        #expect(usage.week == 79)
        #expect(usage.isFiveHourStale(now: usage.sampledAt.addingTimeInterval(6 * 3600)))
        #expect(!usage.isFiveHourStale(now: usage.sampledAt.addingTimeInterval(3600)))
    }

    @Test func findsTheEmailBelongingToTheAccount() {
        let account = Sandbox.accountA
        var blob = Data()
        blob.append(Data("uuid\"$\(Sandbox.accountB)\"\remail_address\"\u{10}teammate@acme.com".utf8))
        blob.append(Data([0x00, 0x01, 0x02]))
        blob.append(Data("uuid\"$\(account)\"\remail_address\"\u{0e}jane@acme.com\"".utf8))
        #expect(DesktopData.email(inBlob: blob, accountID: account) == "jane@acme.com")
        #expect(DesktopData.email(inBlob: blob, accountID: "cccccccc-cccc-cccc-cccc-cccccccccccc") == nil)
    }

    @Test func findsTheEmailInIndexedDBFiles() throws {
        let box = try Sandbox()
        let dir = box.main.appending(path: "IndexedDB/https_claude.ai_0.indexeddb.leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try box.write("junk uuid\"$\(Sandbox.accountA)\"\remail_address\"\u{0e}jane@acme.com junk", to: dir.appending(path: "000003.log"))
        #expect(DesktopData.email(in: box.main, accountID: Sandbox.accountA) == "jane@acme.com")
    }
}

@Suite("Icons and launchers")
struct LauncherTests {
    @Test func icnsHasAValidHeader() {
        let image = IconRenderer.profileIcon(base: NSImage(size: NSSize(width: 16, height: 16)), label: "WORK", color: NSColor(hex: "#1971C2"))
        let data = IconRenderer.icnsData(for: image)
        #expect(data.prefix(4) == Data("icns".utf8))
        let length = data[4..<8].reduce(0) { $0 << 8 | Int($1) }
        #expect(length == data.count)
    }

    @Test func launcherScriptQuotesPaths() throws {
        let box = try Sandbox()
        let manager = ProfileManager(paths: box.paths, cliPath: URL(fileURLWithPath: "/Apps/It's Here/claude-unlimited"))
        let script = manager.launcherScript(for: Profile(id: "work", label: "WORK", email: nil, color: "#000000"))
        #expect(script.contains(#"'/Apps/It'\''s Here/claude-unlimited' open 'work'"#))
        #expect(script.contains("--user-data-dir="))
    }

    @Test func hexColorsParse() {
        let color = NSColor(hex: "#FF8000").usingColorSpace(.sRGB)!
        #expect(abs(color.redComponent - 1) < 0.01)
        #expect(abs(color.greenComponent - 0.5) < 0.01)
        #expect(color.blueComponent < 0.01)
    }
}
