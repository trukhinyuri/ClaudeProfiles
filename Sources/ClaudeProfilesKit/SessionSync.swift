import Foundation

/// Makes Claude Code sessions visible in every profile, whichever account created them.
///
/// Claude Desktop keeps a small index card per Claude Code session under
/// `<data dir>/claude-code-sessions/<account>/<organization>/local_<id>.json`; the conversation itself lives in
/// `~/.claude/projects` and is already shared by all profiles. Copying the cards into every account/organization
/// directory of every profile lets you continue a session from any window.
///
/// Cards are copied, not symlinked: Claude Desktop creates these directories with `mkdir` and fails on symlinks.
public struct SessionSync: Sendable {
    public struct Report: Equatable, Sendable {
        public var pairs = 0
        public var cardsWritten = 0
        public var cardsRemoved = 0
        public var tombstonesWritten = 0
        public var archiveIndexesWritten = 0
        public var backedUp = 0
        public var changes: Int { cardsWritten + cardsRemoved + tombstonesWritten + archiveIndexesWritten }
    }

    static let sessionsFolder = "claude-code-sessions"
    static let archiveIndex = "archived-sessions.idx"

    public let paths: Paths
    public let dataDirs: [URL]
    private var fm: FileManager { .default }

    /// - Parameter dataDirs: every Claude Desktop data directory to keep in sync, main one included.
    public init(paths: Paths, dataDirs: [URL]) {
        self.paths = paths
        self.dataDirs = dataDirs
    }

    /// - Parameter propagateDeletions: also spread "session deleted" markers and drop the deleted cards.
    ///   Do this only while no Claude Desktop window is open; otherwise sync only adds and updates.
    @discardableResult
    public func run(propagateDeletions: Bool, now: Date = Date()) throws -> Report {
        var report = Report()
        let pairs = self.pairs()
        report.pairs = pairs.count

        var cards: [String: (modified: Date, data: Data)] = [:]
        var tombstones = Set<String>()
        var archiveLists: [String: Set<String>] = [:]   // folder path → archived IDs, for folders that have an index
        var archiveVersion: Any = 1

        for pair in pairs {
            for url in SyncFolders.contents(of: pair) {
                let name = url.lastPathComponent
                if name.hasPrefix("local_"), name.hasSuffix(".json") {
                    guard let modified = SyncFolders.modificationDate(url) else { continue }
                    if let known = cards[name], known.modified >= modified { continue }
                    if let data = try? Data(contentsOf: url) { cards[name] = (modified, data) }
                } else if name.hasPrefix("deleted_") {
                    tombstones.insert(name)
                } else if name == Self.archiveIndex, let index = readJSON(url) {
                    archiveLists[pair.path] = Set(index["archived"] as? [String] ?? [])
                    archiveVersion = index["v"] ?? archiveVersion
                }
            }
        }

        // Never resurrect a session that was deleted in any profile.
        let deletedIDs = Set(tombstones.map { String($0.dropFirst("deleted_".count)) })
        cards = cards.filter { name, _ in
            let id = String(name.dropFirst("local_".count).dropLast(".json".count))
            return !deletedIDs.contains(id) && !deletedIDs.contains("local_" + id)
        }

        // Archive lists are merged by union. Honoring removals would be unsafe: a running Claude can write back
        // a stale list, which would look like un-archiving everything added since it loaded.
        let archived = archiveLists.values.reduce(into: Set<String>()) { $0.formUnion($1) }

        let backup = Backup(paths: paths, now: now)
        for pair in pairs {
            // As given, not as listed: Claude writes paths with the data directory it was started with.
            let listed = pair.resolvingSymlinksInPath().path
            let dataDir = dataDirs.first { listed.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
                ?? pair.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let present = Set(SyncFolders.contents(of: pair).map(\.lastPathComponent))
            for (name, card) in cards {
                let target = pair.appending(path: name)
                var data = localized(card.data, for: dataDir), modified = card.modified
                if present.contains(name) {
                    guard let current = SyncFolders.modificationDate(target), let own = try? Data(contentsOf: target) else { continue }
                    if current >= card.modified.addingTimeInterval(-1) {
                        // This copy is as new as any; it may still need this window's scratch folder path.
                        data = localized(own, for: dataDir)
                        modified = current
                    }
                    guard own != data else { continue }
                    if try backup.save(target) { report.backedUp += 1 }
                    // Claude may have just updated this copy; never replace a newer card with an older one.
                    guard SyncFolders.modificationDate(target) == current, (try? Data(contentsOf: target)) == own else { continue }
                }
                try data.write(to: target, options: .atomic)
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
                report.cardsWritten += 1
            }
            if propagateDeletions {
                for tombstone in tombstones where !present.contains(tombstone) {
                    fm.createFile(atPath: pair.appending(path: tombstone).path, contents: Data())
                    report.tombstonesWritten += 1
                }
                for name in present where name.hasPrefix("local_") && name.hasSuffix(".json") && cards[name] == nil {
                    let target = pair.appending(path: name)
                    if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                    try fm.removeItem(at: target)
                    report.cardsRemoved += 1
                }
            }
            let url = pair.appending(path: Self.archiveIndex)
            if !archived.isEmpty {
                if archiveLists[pair.path] != archived {
                    if fm.fileExists(atPath: url.path), try backup.save(url) { report.backedUp += 1 }
                    let object: [String: Any] = ["v": archiveVersion, "archived": archived.sorted()]
                    try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
                    report.archiveIndexesWritten += 1
                }
            }
        }
        backup.prune()
        return report
    }

    /// A session started in a "No folder" scratch workspace keeps that folder in the data directory of the window
    /// that started it. Claude shows a session as one only when `originCwd` is inside its own data directory, so
    /// each window's copy of the card names that window's data directory there. `cwd`, where the session actually
    /// runs and where its conversation is filed, stays the same everywhere.
    func localized(_ card: Data, for dataDir: URL) -> Data {
        let key = Data(#""originCwd":""#.utf8)
        guard let keyRange = card.range(of: key),
              let end = card[keyRange.upperBound...].firstIndex(of: UInt8(ascii: "\"")),
              let value = String(data: card[keyRange.upperBound..<end], encoding: .utf8), !value.contains("\\")
        else { return card }
        let folder = "/scratch-workspaces/"
        for dir in dataDirs where value.hasPrefix(dir.path + folder) {
            let path = dataDir.path + folder + value.dropFirst(dir.path.count + folder.count)
            guard path != value else { return card }
            var result = card
            result.replaceSubrange(keyRange.upperBound..<end, with: Data(path.utf8))
            return result
        }
        return card
    }

    /// Every `<account>/<organization>` session directory across all data directories.
    func pairs() -> [URL] { SyncFolders.pairs(dataDirs: dataDirs, folder: Self.sessionsFolder) }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Copies a file into `Backups/<date>/` before Claude Profiles overwrites or removes it.
/// Day folders older than a week go to the Trash, never straight to deletion.
struct Backup {
    let paths: Paths
    let now: Date
    /// Where pruned backups go; the Trash unless a test substitutes it.
    var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    static let keepDays = 7

    var dayDir: URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return paths.backupsDir.appending(path: formatter.string(from: now), directoryHint: .isDirectory)
    }

    /// Overwrites keep the first version of the day; removals are always kept.
    /// - Returns: `true` if a copy was made.
    func save(_ url: URL, everyTime: Bool = false) throws -> Bool {
        let base = paths.applicationSupport.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
        var target = dayDir.appending(path: relative)
        if FileManager.default.fileExists(atPath: target.path) {
            guard everyTime else { return false }
            target = target.deletingLastPathComponent().appending(path: "\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))-\(target.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: target)
        return true
    }

    /// Writes `values` as JSON to `relative` in today's folder, for data that can't be copied as a file.
    /// Every call gets its own file.
    func saveValues(_ values: [String: Any], as relative: String) throws {
        var target = dayDir.appending(path: relative)
        if FileManager.default.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent().appending(path: "\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))-\(target.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: target, options: .atomic)
    }

    /// Moves backup day folders older than `keepDays` to the Trash.
    @discardableResult
    func prune() -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var moved = 0
        for day in (try? FileManager.default.contentsOfDirectory(at: paths.backupsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let date = formatter.date(from: day.lastPathComponent), date < cutoff else { continue }
            if (try? discard(day)) != nil { moved += 1 }
        }
        return moved
    }
}

