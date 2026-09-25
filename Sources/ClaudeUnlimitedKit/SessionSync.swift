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

    struct Pair: Hashable { let dir: URL }

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
            for url in contents(of: pair.dir) {
                let name = url.lastPathComponent
                if name.hasPrefix("local_"), name.hasSuffix(".json") {
                    guard let modified = modificationDate(url) else { continue }
                    if let known = cards[name], known.modified >= modified { continue }
                    if let data = try? Data(contentsOf: url) { cards[name] = (modified, data) }
                } else if name.hasPrefix("deleted_") {
                    tombstones.insert(name)
                } else if name == Self.archiveIndex, let index = readJSON(url) {
                    archiveLists[pair.dir.path] = Set(index["archived"] as? [String] ?? [])
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
            let present = Set(contents(of: pair.dir).map(\.lastPathComponent))
            for (name, card) in cards {
                let target = pair.dir.appending(path: name)
                if present.contains(name) {
                    guard let modified = modificationDate(target), modified < card.modified.addingTimeInterval(-1),
                          (try? Data(contentsOf: target)) != card.data else { continue }
                    if try backup.save(target) { report.backedUp += 1 }
                    // Claude may have just updated this copy; never replace a newer card with an older one.
                    guard let latest = modificationDate(target), latest < card.modified.addingTimeInterval(-1) else { continue }
                }
                try card.data.write(to: target, options: .atomic)
                try? fm.setAttributes([.modificationDate: card.modified], ofItemAtPath: target.path)
                report.cardsWritten += 1
            }
            if propagateDeletions {
                for tombstone in tombstones where !present.contains(tombstone) {
                    fm.createFile(atPath: pair.dir.appending(path: tombstone).path, contents: Data())
                    report.tombstonesWritten += 1
                }
                for name in present where name.hasPrefix("local_") && name.hasSuffix(".json") && cards[name] == nil {
                    let target = pair.dir.appending(path: name)
                    if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                    try fm.removeItem(at: target)
                    report.cardsRemoved += 1
                }
            }
            let url = pair.dir.appending(path: Self.archiveIndex)
            if !archived.isEmpty {
                if archiveLists[pair.dir.path] != archived {
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

    /// Every `<account>/<organization>` session directory across all data directories.
    func pairs() -> [Pair] {
        var result: [Pair] = []
        for dataDir in dataDirs {
            let sessions = dataDir.appending(path: Self.sessionsFolder, directoryHint: .isDirectory)
            for account in contents(of: sessions) where account.lastPathComponent.count == 36 && isRealDirectory(account) {
                for org in contents(of: account) where !org.lastPathComponent.hasPrefix(".") && isRealDirectory(org) {
                    result.append(Pair(dir: org))
                }
            }
        }
        return result
    }

    private func contents(of dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Copies a file into `Backups/<date>/` before ClaudeUnlimited overwrites or removes it.
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

