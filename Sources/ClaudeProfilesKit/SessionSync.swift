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
        removeDeadScratchLinks()
        backup.prune()
        return report
    }

    static let scratchFolder = "/scratch-workspaces/"

    /// A session started in a "No folder" scratch workspace keeps that folder in the data directory of the window
    /// that started it. Claude lists a session under "No folder" only when `originCwd` is inside its own data
    /// directory, and offers side questions (`/btw`) only when `cwd` is the same path. So every other window gets a
    /// link to the folder at the same place in its own data directory, and its copy of the card names that link as
    /// both. Claude Code resolves the link, so the conversation stays filed under the folder's real path. Claude
    /// never sweeps or removes those links: it only cleans up real folders of its own account.
    ///
    /// When the folder is gone, or the link can't be made, only `originCwd` is changed, which keeps the session
    /// under "No folder" without side questions.
    func localized(_ card: Data, for dataDir: URL) -> Data {
        let strings = Self.topLevelStrings(in: card)
        guard let originRange = strings["originCwd"], let origin = String(data: card[originRange], encoding: .utf8),
              let workspace = scratchWorkspace(origin) else { return card }
        let here = dataDir.path + Self.scratchFolder + workspace
        var changes = [(originRange, origin)]
        if let cwdRange = strings["cwd"], let cwd = String(data: card[cwdRange], encoding: .utf8),
           scratchWorkspace(cwd) == workspace, workspace.split(separator: "/").count == 3,
           let owner = owner(of: cwd, workspace: workspace),
           owner.path == dataDir.path || linkScratchFolder(at: here, to: owner.path + Self.scratchFolder + workspace) {
            changes.append((cwdRange, cwd))
        }
        var result = card
        for (range, value) in changes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) where value != here {
            result.replaceSubrange(range, with: Data(here.utf8))
        }
        return result
    }

    /// `<account>/<organization>/<folder>` of a path inside any data directory's scratch workspaces.
    private func scratchWorkspace(_ path: String) -> String? {
        for dir in dataDirs where path.hasPrefix(dir.path + Self.scratchFolder) {
            let rest = String(path.dropFirst(dir.path.count + Self.scratchFolder.count))
            return rest.isEmpty || rest.split(separator: "/").contains { $0 == "." || $0 == ".." } ? nil : rest
        }
        return nil
    }

    /// The data directory whose real scratch folder `cwd` leads to, following any link.
    private func owner(of cwd: String, workspace: String) -> URL? {
        let real = URL(filePath: cwd).resolvingSymlinksInPath().path
        return dataDirs.first { dir in
            let folder = dir.path + Self.scratchFolder + workspace
            return isFolder(folder) && URL(filePath: folder).resolvingSymlinksInPath().path == real
        }
    }

    private func isFolder(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// Makes `path` a link to `folder`, or checks that it already is one. Anything else at `path` is left alone.
    private func linkScratchFolder(at path: String, to folder: String) -> Bool {
        if (try? fm.attributesOfItem(atPath: path)) == nil {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: path, withDestinationPath: folder)
        }
        return (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
            && (try? fm.destinationOfSymbolicLink(atPath: path)) == folder
    }

    /// Removes links made by `localized(_:for:)` whose folder is gone, such as after that session or the profile
    /// that started it was removed. Only links to the same place in another data directory are touched.
    @discardableResult
    func removeDeadScratchLinks() -> Int {
        var removed = 0
        for dir in dataDirs {
            let root = dir.path + Self.scratchFolder
            for account in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                for org in (try? fm.contentsOfDirectory(atPath: root + account)) ?? [] {
                    let orgPath = root + account + "/" + org
                    for name in (try? fm.contentsOfDirectory(atPath: orgPath)) ?? [] {
                        let link = orgPath + "/" + name
                        guard (try? fm.attributesOfItem(atPath: link)[.type] as? FileAttributeType) == .typeSymbolicLink,
                              let folder = try? fm.destinationOfSymbolicLink(atPath: link), folder.hasPrefix("/"),
                              folder.hasSuffix(Self.scratchFolder + account + "/" + org + "/" + name),
                              !fm.fileExists(atPath: folder) else { continue }
                        if (try? fm.removeItem(atPath: link)) != nil { removed += 1 }
                    }
                }
            }
        }
        return removed
    }

    /// Where each top-level string value of a card is, keyed by name; values with escapes and nested objects are
    /// skipped. Editing a card in place keeps the rest of it byte for byte as Claude wrote it.
    static func topLevelStrings(in card: Data) -> [String: Range<Data.Index>] {
        let bytes = [UInt8](card), base = card.startIndex
        var result: [String: Range<Data.Index>] = [:]
        var depth = 0, index = 0, key: String?
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                var end = index + 1, escaped = false
                while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
                    if bytes[end] == UInt8(ascii: "\\") { escaped = true; end += 1 }
                    end += 1
                }
                guard end < bytes.count else { return result }
                if depth == 1 {
                    var next = end + 1
                    while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
                    if next < bytes.count, bytes[next] == UInt8(ascii: ":") {
                        key = escaped ? nil : String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                    } else if let name = key, !escaped {
                        result[name] = (base + index + 1)..<(base + end)
                    }
                }
                index = end + 1
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1; index += 1
            default: index += 1
            }
        }
        return result
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

