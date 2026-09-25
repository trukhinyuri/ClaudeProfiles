import Foundation
import Testing
@testable import ClaudeProfilesKit

private let claudeOrigin = "https://claude.ai"

/// `Fixtures/LocalStorageFixture` is a real Chromium-format LevelDB database, built by a small C++ program
/// against Homebrew leveldb (dev-time only, not part of this package). It holds "https://claude.ai" entries
/// covering a Latin-1 key/value, a UTF-16 key and value, a key overwritten twice, a key written then
/// deleted, a "https://example.com" entry that must not leak in, and enough padding to force a real,
/// Snappy-compressed `.ldb` table via `CompactRange`; one final write lands only in the `.log` file.
private func fixtureRoot() -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures/LocalStorageFixture", directoryHint: .isDirectory)
}

private func expectedFixtureItems() -> [String: String] {
    var items: [String: String] = [
        "sidebarWidth": "240",
        "pinnedItems": "chat,docs,history",
        "status": "✅ done",
        "编辑器": "on",
        "counter": "2",
        "afterCompact": "yes",
    ]
    for i in 0..<150 {
        items["pad" + String(format: "%04d", i)] = "padding-value-\(i)-" + String(repeating: "x", count: 180)
    }
    return items
}

/// A private, writable copy of the fixture database in a fresh temp directory.
private func copyFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "ls-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let dest = root.appending(path: "data", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixtureRoot(), to: dest)
    return dest
}

private func logFileCount(_ storage: LocalStorage) throws -> Int {
    try FileManager.default.contentsOfDirectory(at: storage.dbDir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".log") }.count
}

/// Blocks for the holder process's first line of output (its confirmation that the lock is held).
private func readOneLine(_ handle: FileHandle) throws -> String {
    var buffer = Data()
    while !buffer.contains(0x0A) {
        let chunk = handle.availableData
        guard !chunk.isEmpty else { break }
        buffer.append(chunk)
    }
    return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("Local Storage")
struct LocalStorageTests {
    @Test func readsExactlyTheLiveItemsForAnOrigin() throws {
        let storage = LocalStorage(dataDir: fixtureRoot())
        #expect(storage.exists)
        #expect(!storage.isInUse)
        #expect(try storage.items(origin: claudeOrigin) == expectedFixtureItems())
    }

    @Test func otherOriginsAndOverwrittenOrDeletedKeysDoNotLeakIn() throws {
        let storage = LocalStorage(dataDir: fixtureRoot())
        let items = try storage.items(origin: claudeOrigin)
        #expect(items["toDelete"] == nil, "deleted key must not appear")
        #expect(items["counter"] == "2", "only the newest write of an overwritten key must appear")
        #expect(items["otherOrigin"] == nil, "a different origin's key must not appear under this origin's prefix")
        #expect(try storage.items(origin: "https://example.com")["otherOrigin"] == "shouldNotAppear",
                "reading with the matching origin still finds it")
    }

    @Test func missingDataDirDoesNotExistAndIsNotInUse() {
        let storage = LocalStorage(dataDir: FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString)"))
        #expect(!storage.exists)
        #expect(!storage.isInUse)
    }

    @Test func updateRoundTripsSetsAndRemovalsAndKeepsExistingFiles() throws {
        let dataDir = try copyFixture()
        let storage = LocalStorage(dataDir: dataDir)
        let originalLogCount = try logFileCount(storage)

        try storage.update(origin: claudeOrigin, set: ["sidebarWidth": "320", "newPref": "on"], remove: ["pad0000"])

        var items = try storage.items(origin: claudeOrigin)
        #expect(items["sidebarWidth"] == "320")
        #expect(items["newPref"] == "on")
        #expect(items["pad0000"] == nil)
        #expect(items["pinnedItems"] == "chat,docs,history", "keys not touched by the update survive untouched")
        #expect(try logFileCount(storage) == originalLogCount + 1, "the update adds a new log file rather than editing one")

        // A second update must not collide with the first: new file number, new sequence.
        try storage.update(origin: claudeOrigin, set: ["sidebarWidth": "400"], remove: ["newPref"])
        items = try storage.items(origin: claudeOrigin)
        #expect(items["sidebarWidth"] == "400")
        #expect(items["newPref"] == nil)
        #expect(try logFileCount(storage) == originalLogCount + 2)
    }

    /// A POSIX `fcntl` write lock never conflicts with another lock request from the *same* process, even
    /// on a different file descriptor — the lock is keyed by (process, inode), not by descriptor. So
    /// exercising `isInUse`/`update()` against a held lock needs the lock held by a genuinely separate
    /// process; this spawns the system Perl to `flock()` the `LOCK` file and hold it until told to stop.
    @Test func updateThrowsWhileTheDatabaseIsLocked() throws {
        let dataDir = try copyFixture()
        let storage = LocalStorage(dataDir: dataDir)
        let lockPath = storage.dbDir.appending(path: "LOCK").path

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", #"$|=1; open(my $fh, "+<", $ARGV[0]) or die $!; flock($fh, 2) or die $!; print "locked\n"; <STDIN>;"#, lockPath]
        let stdout = Pipe()
        let stdin = Pipe()
        holder.standardOutput = stdout
        holder.standardInput = stdin
        try holder.run()
        defer {
            stdin.fileHandleForWriting.closeFile()
            holder.waitUntilExit()
        }

        #expect(try readOneLine(stdout.fileHandleForReading) == "locked", "test setup: the holder process must confirm its lock")
        #expect(storage.isInUse)
        #expect(throws: LocalStorageError.self) {
            try storage.update(origin: claudeOrigin, set: ["x": "y"], remove: [])
        }
    }

    @Test func fileNamesMatchLevelDBForEveryNumber() {
        #expect(LevelDBDatabase.fileName(number: 7, suffix: "log") == "000007.log")
        #expect(LevelDBDatabase.fileName(number: 1_234_567, suffix: "ldb") == "1234567.ldb")
        #expect(LevelDBDatabase.fileName(number: 5_000_000_000, suffix: "log") == "5000000000.log")
    }

    @Test func chromiumStringEncodingRoundTrips() {
        for value in ["", "ascii only", "line\nbreak", String(repeating: "z", count: 300)] {
            #expect(ChromiumKey.decodeString(ChromiumKey.encodeString(value)) == value)
        }
        for value in ["✅ done", "编辑器", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢"] {
            let encoded = ChromiumKey.encodeString(value)
            #expect(encoded.first == 0x00, "non-Latin-1 text must use the UTF-16LE tag")
            #expect(ChromiumKey.decodeString(encoded) == value)
        }
        #expect(ChromiumKey.encodeString("abc").first == 0x01, "Latin-1-range text must use the Latin-1 tag")
    }
}
