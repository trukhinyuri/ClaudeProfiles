import Foundation

/// Makes Cowork sessions visible in every profile, whichever account created them.
///
/// Claude Desktop keeps a small index card per Cowork session under
/// `<data dir>/local-agent-mode-sessions/<account>/<organization>/local_<id>.json`. The card holds absolute
/// paths, so a copy in another account/organization folder works from there. Next to each card is a working
/// folder `local_<id>/` and per-organization files (`cowork-*-cache.json`, `remote-session-spaces.json`,
/// `scheduled-tasks.json`, `rpm/`, 8-hex-char sandbox folders); only `local_*.json` cards are shared, and
/// `scheduled-tasks.json` never is, since a shared task would run in every open window at once.
///
/// Cowork keeps no deletion tombstones, so a card missing from a folder that used to have it is read as a
/// deletion there. `CoworkSync` remembers, in `cowork-sync.json`, which cards each folder held after the last
/// run, so it can tell a real deletion from a folder that simply hasn't been synced yet.
public struct CoworkSync: Sendable {
    public struct Report: Equatable, Sendable {
        public var pairs = 0
        public var cardsWritten = 0
        public var cardsRemoved = 0
        public var backedUp = 0
        public var changes: Int { cardsWritten + cardsRemoved }
    }

    static let sessionsFolder = "local-agent-mode-sessions"

    public let paths: Paths
    public let dataDirs: [URL]
    private var fm: FileManager { .default }

    var stateFile: URL { paths.stateDir.appending(path: "cowork-sync.json") }

    /// - Parameter dataDirs: every Claude Desktop data directory to keep in sync, main one included.
    public init(paths: Paths, dataDirs: [URL]) {
        self.paths = paths
        self.dataDirs = dataDirs
    }

    /// - Parameter propagateDeletions: also remove cards that were deleted in some folder from every folder.
    ///   Do this only while no Claude Desktop window is open; otherwise sync only adds and updates.
    @discardableResult
    public func run(propagateDeletions: Bool, now: Date = Date()) throws -> Report {
        var report = Report()
        let pairs = self.pairs()
        report.pairs = pairs.count

        var cards: [String: (modified: Date, data: Data)] = [:]
        var present: [String: Set<String>] = [:]   // folder path → card names currently in it
        for pair in pairs {
            var here: Set<String> = []
            for url in SyncFolders.contents(of: pair) {
                let name = url.lastPathComponent
                guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
                here.insert(name)
                guard let modified = SyncFolders.modificationDate(url) else { continue }
                if let known = cards[name], known.modified >= modified { continue }
                if let data = try? Data(contentsOf: url) { cards[name] = (modified, data) }
            }
            present[pair.path] = here
        }

        var state = State.load(from: stateFile)
        var deletedIn = state.deletedIn.mapValues(Set.init)
        for pair in pairs {
            guard let last = state.present[pair.path] else { continue }   // new folder: never read as deletions
            let missing = Set(last).subtracting(present[pair.path] ?? [])
            if !missing.isEmpty { deletedIn[pair.path, default: []].formUnion(missing) }
        }
        // A card someone is still touching after the last run outlives a deletion seen elsewhere.
        let lastRun = state.lastRun ?? .distantPast
        let revived = Set(cards.filter { $0.value.modified > lastRun }.keys)
        for key in deletedIn.keys { deletedIn[key]?.subtract(revived) }
        deletedIn = deletedIn.filter { !$0.value.isEmpty }
        let confirmedDeletions = deletedIn.values.reduce(into: Set<String>()) { $0.formUnion($1) }

        let backup = Backup(paths: paths, now: now)
        var nextPresent: [String: Set<String>] = [:]
        for pair in pairs {
            let here = present[pair.path] ?? []
            var wrote = here
            for (name, card) in cards {
                let target = pair.appending(path: name)
                if confirmedDeletions.contains(name) {
                    if propagateDeletions, here.contains(name) {
                        if try backup.save(target, everyTime: true) { report.backedUp += 1 }
                        try fm.removeItem(at: target)
                        report.cardsRemoved += 1
                        wrote.remove(name)
                    }
                    continue   // never copied back anywhere while its deletion isn't resolved
                }
                if here.contains(name) {
                    guard let modified = SyncFolders.modificationDate(target), modified < card.modified.addingTimeInterval(-1),
                          (try? Data(contentsOf: target)) != card.data else { continue }
                    if try backup.save(target) { report.backedUp += 1 }
                    // Claude may have just updated this copy; never replace a newer card with an older one.
                    guard let latest = SyncFolders.modificationDate(target), latest < card.modified.addingTimeInterval(-1) else { continue }
                }
                try card.data.write(to: target, options: .atomic)
                try? fm.setAttributes([.modificationDate: card.modified], ofItemAtPath: target.path)
                report.cardsWritten += 1
                wrote.insert(name)
            }
            nextPresent[pair.path] = wrote
        }
        backup.prune()

        let stillAround = Set(nextPresent.values.joined())
        state.lastRun = now
        state.present = nextPresent.mapValues { Array($0).sorted() }
        state.deletedIn = deletedIn.mapValues { Array($0.intersection(stillAround)).sorted() }.filter { !$0.value.isEmpty }
        try state.save(to: stateFile)

        return report
    }

    /// Removes, from every folder, the cards of sessions whose working folder is inside `dataDir`: a removed
    /// profile's Cowork sessions go to the Trash with it and can't be opened from other windows. Each card is backed up.
    /// - Returns: how many cards were removed.
    @discardableResult
    public func removeCards(workingIn dataDir: URL, now: Date = Date()) throws -> Int {
        let inside = dataDir.standardizedFileURL.path + "/"
        let backup = Backup(paths: paths, now: now)
        var removed = 0
        for pair in pairs() {
            for url in SyncFolders.contents(of: pair) where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let cwd = card["cwd"] as? String, cwd.hasPrefix(inside) else { continue }
                _ = try backup.save(url, everyTime: true)
                try fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    /// Every `<account>/<organization>` Cowork directory across all data directories.
    func pairs() -> [URL] { SyncFolders.pairs(dataDirs: dataDirs, folder: Self.sessionsFolder) }

    /// What `run` synced last time, so a card missing from a folder can be told apart from one never synced there.
    struct State: Codable, Sendable {
        var lastRun: Date?
        var present: [String: [String]] = [:]     // folder path → card names present there after the run
        var deletedIn: [String: [String]] = [:]    // folder path → card names known deleted specifically there

        static func load(from url: URL) -> State {
            guard let data = try? Data(contentsOf: url) else { return State() }
            // .secondsSince1970, not .iso8601: telling an edit from the deletion it outlives needs sub-second
            // precision, which ISO 8601's whole-second formatting would throw away on every round trip.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return (try? decoder.decode(State.self, from: data)) ?? State()
        }

        func save(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }
}
