import Foundation

/// Gives a profile's window the main app's interface state before it starts: sidebar layout, pinned and starred
/// sessions, custom groups, unread markers, filters, editor preferences and dismissed tips. Claude keeps these in
/// three places: its Local Storage; `preferences.epitaxyPrefs` in `claude_desktop_config.json`, which it reads
/// before Local Storage; and, for starred sessions and expanded sidebar sections, IndexedDB. A few are kept per
/// account, so the main app's account is swapped for the profile's.
/// Sign-in data, drafts, caches and anything that differs by plan (such as the default model) are left alone.
///
/// The main app wins, except for a value changed only in the profile's window since the last run: that one stays.
/// Run it only while the profile's window is closed.
public struct InterfaceSync: Sendable {
    static let origin = "https://claude.ai"
    /// Copied as they are; removed from the profile when the main app doesn't have them.
    static let keys: Set<String> = [
        "dframe-unpinned-epitaxy-project-ids", "LSS-persisted.dframe-local-slice", "LSS-persisted.dframe-group-scopes",
        "LSS-persisted.starred-local-code-sessions", "LSS-persisted.starred-session-groups",
        "LSS-persisted.starred-cowork-spaces", "LSS-persisted.starred-local-routines",
        "LSS-sidebar-selected-mode", "ccd-sessions-filter", "epitaxy-unread-v1", "epitaxy.sessionRailSections",
        "code-session-pills", "epitaxy-editor-prefs", "LSS-persisted.epitaxy-transcript-links-in-preview",
        "LSS-persisted.epitaxy-transcript-links-chooser-seen", "LSS-persisted.epitaxy-default-transcript-view-nudge",
        "persisted.epitaxy-split-suggestion",
    ]
    /// Keys starting with these are copied but never removed: the profile may have its own.
    static let prefixes = ["epitaxy-session-result:", "banner_dismissed:"]
    /// Kept per account: `<prefix><account UUID>`.
    static let accountPrefixes = [
        "LSS-persisted.code-sessions-status-filter.", "LSS-persisted.code-sessions-selected-environments-v2.",
        "LSS-persisted.epitaxy-folder-permission-mode.", "LSS-persisted.epitaxy-auto-default-notice-seen.",
        "LSS-persisted.epitaxy-auto-setup-band-seen.", "LSS-persisted.epitaxy-auto-reinvite-first-block-seen.",
        "LSS-persisted.epitaxy-try-auto-coach-seen-at.", "LSS-persisted.epitaxy-auto-entry-warning-seen.",
    ]
    /// The sidebar's store, merged field by field.
    static let sidebarKey = "dframe-store"
    /// Sidebar fields about the profile's own account, never copied. So is any field ending in `ByOrg` or `ScopeKey`,
    /// and any other field ending in `ByScope`.
    static let ownSidebarFields: Set<String> = ["pendingLegacyGroupMigration"]
    /// Custom sidebar groups: the main app's groups for its account become the profile's.
    static let groupsField = "customGroupsByScope"

    /// Starred sessions and expanded sidebar sections, in IndexedDB. Claude fills these from `epitaxyPrefs` only
    /// when they are empty, so they have to be shared themselves.
    static let pinDatabase = "keyval-store", pinObjectStore = "keyval"
    static let pinKeys = ["store:pin-state:dframe-starred-code", "store:pin-state:dframe-session-groups",
                          "store:pin-state:dframe-unpinned-epitaxy-project"]

    static let desktopConfig = "claude_desktop_config.json"

    /// The `epitaxyPrefs` name of a Local Storage key, for the keys Claude keeps in both places.
    static func prefsName(_ key: String) -> String? {
        for prefix in ["LSS-persisted.", "persisted."] where key.hasPrefix(prefix) { return String(key.dropFirst(prefix.count)) }
        return key == "ccd-sessions-filter" ? key : nil
    }

    static let prefsKeys = Set(keys.compactMap(prefsName))
    static let prefsAccountPrefixes = accountPrefixes.compactMap(prefsName)

    /// Whether this `epitaxyPrefs` key is shared here, so `SettingsSync` leaves it alone.
    static func sharesPref(_ key: String) -> Bool {
        prefsKeys.contains(key) || prefsAccountPrefixes.contains(where: key.hasPrefix)
    }

    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) { self.paths = paths }

    func stateFile(for profileID: String) -> URL {
        paths.stateDir.appending(path: "Interface/\(profileID).json")
    }

    /// Stands for "no such key" in comparisons and in the state file.
    static let missing = "\u{0}"

    /// - Returns: how many entries changed.
    @discardableResult
    public func run(into dataDir: URL, profileID: String, now: Date = Date()) throws -> Int {
        let source = LocalStorage(dataDir: paths.mainDataDir), target = LocalStorage(dataDir: dataDir)
        guard !target.isInUse, let mainAccount = DesktopData.accountID(in: paths.mainDataDir),
              let account = DesktopData.accountID(in: dataDir) else { return 0 }
        let backup = Backup(paths: paths, now: now)
        var base = Self.readState(stateFile(for: profileID))
        var changed = 0, failure: Error?
        // Each place is merged on its own copy of the agreed values, kept only if its write went through:
        // recording a value that never reached the profile would later look like a change made there.
        func stage(_ merge: (inout [String: String]) throws -> Int) {
            var attempt = base
            do {
                changed += try merge(&attempt)
                base = attempt
            } catch {
                failure = failure ?? error
            }
        }
        if source.exists, target.exists {
            stage { try mergeLocalStorage(source: source, target: target, dataDir: dataDir,
                                          mainAccount: mainAccount, account: account, base: &$0, backup: backup) }
        }
        stage { try mergePrefs(into: dataDir, mainAccount: mainAccount, account: account, base: &$0, backup: backup) }
        stage { try mergePins(into: dataDir, profileID: profileID, base: &$0, backup: backup) }
        try Self.writeState(base, to: stateFile(for: profileID))
        if let failure { throw failure }
        return changed
    }

    private func mergeLocalStorage(source: LocalStorage, target: LocalStorage, dataDir: URL, mainAccount: String,
                                   account: String, base: inout [String: String], backup: Backup) throws -> Int {
        // The main app is running, so a compaction can swap files while they are read; one retry covers that.
        let main = try (try? source.items(origin: Self.origin)) ?? source.items(origin: Self.origin)
        let own = try target.items(origin: Self.origin)

        var wanted: [String: String] = [:]   // key -> value the main app implies, or `missing`
        for key in Self.keys { wanted[key] = main[key] ?? Self.missing }
        for (key, value) in main where Self.prefixes.contains(where: key.hasPrefix) { wanted[key] = value }
        for prefix in Self.accountPrefixes { wanted[prefix + account] = main[prefix + mainAccount] ?? Self.missing }

        var set: [String: String] = [:], remove: Set<String> = []
        for (key, mainValue) in wanted {
            let ownValue = own[key] ?? Self.missing
            let mainText = Self.comparable(mainValue), ownText = Self.comparable(ownValue)
            switch Self.resolve(own: ownText, main: mainText, base: base[key]) {
            case .main:
                base[key] = mainText
                guard mainText != ownText else { continue }
                if mainValue == Self.missing { remove.insert(key) } else { set[key] = mainValue }
            case .own:
                continue
            }
        }
        if let sidebar = mergeSidebar(main: main[Self.sidebarKey], own: own[Self.sidebarKey], base: &base,
                                      mainScope: Self.scope(in: main, account: mainAccount, dataDir: paths.mainDataDir),
                                      scope: Self.scope(in: own, account: account, dataDir: dataDir)) {
            set[Self.sidebarKey] = sidebar
        }

        if !set.isEmpty || !remove.isEmpty {
            _ = try backup.save(target.dbDir)
            try target.update(origin: Self.origin, set: set, remove: remove)
        }
        return set.count + remove.count
    }

    /// The same settings in `claude_desktop_config.json` → `preferences.epitaxyPrefs`, where Claude looks first.
    /// A key the main app doesn't have is removed, so Claude falls back to Local Storage, as it does in the main app.
    private func mergePrefs(into dataDir: URL, mainAccount: String, account: String,
                            base: inout [String: String], backup: Backup) throws -> Int {
        let url = dataDir.appending(path: Self.desktopConfig)
        guard let mainConfig = SettingsSync.readJSON(paths.mainDataDir.appending(path: Self.desktopConfig)),
              var config = SettingsSync.readJSON(url) else { return 0 }
        let mainPrefs = (mainConfig["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] ?? [:]
        var preferences = config["preferences"] as? [String: Any] ?? [:]
        let own = preferences["epitaxyPrefs"] as? [String: Any] ?? [:]

        var wanted: [(key: String, value: Any?)] = Self.prefsKeys.map { ($0, mainPrefs[$0]) }
        wanted += Self.prefsAccountPrefixes.map { ($0 + account, mainPrefs[$0 + mainAccount]) }

        var prefs = own, changed = 0
        for (key, mainValue) in wanted {
            let mainText = mainValue.map(Self.canonical) ?? Self.missing
            let ownText = own[key].map(Self.canonical) ?? Self.missing
            guard Self.resolve(own: ownText, main: mainText, base: base["prefs:" + key]) == .main else { continue }
            base["prefs:" + key] = mainText
            guard mainText != ownText else { continue }
            prefs[key] = mainValue
            changed += 1
        }
        guard changed > 0 else { return 0 }
        preferences["epitaxyPrefs"] = prefs
        config["preferences"] = preferences
        _ = try backup.save(url)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return changed
    }

    /// Starred sessions and expanded sections in IndexedDB. Each value is copied as the main app serialized it.
    /// A store that is missing, in another format or another version on either side is left alone.
    private func mergePins(into dataDir: URL, profileID: String, base: inout [String: String], backup: Backup) throws -> Int {
        let source = IndexedDBStore(dataDir: paths.mainDataDir, database: Self.pinDatabase, objectStore: Self.pinObjectStore)
        let target = IndexedDBStore(dataDir: dataDir, database: Self.pinDatabase, objectStore: Self.pinObjectStore)
        guard source.exists, target.exists, !target.isInUse else { return 0 }
        // The main app is running; one retry covers a compaction swapping files during the read.
        guard let main = try (try? source.read()) ?? source.read(), let own = try target.read(),
              main.dataVersion == own.dataVersion else { return 0 }

        var put: [String: [UInt8]] = [:], previous: [String: Any] = [:]
        for key in Self.pinKeys {
            guard let mainRecord = main.records[key], !main.blobKeys.contains(key), !own.blobKeys.contains(key),
                  let mainStore = mainRecord.string.flatMap(Self.object), let mainState = mainStore["state"] else { continue }
            var ownText = Self.missing
            if let ownRecord = own.records[key] {
                guard let ownStore = ownRecord.string.flatMap(Self.object), let ownState = ownStore["state"],
                      Self.canonical(ownStore["version"] ?? NSNull()) == Self.canonical(mainStore["version"] ?? NSNull())
                else { continue }
                ownText = Self.canonical(ownState)
            }
            let mainText = Self.canonical(mainState)
            guard Self.resolve(own: ownText, main: mainText, base: base["idb:" + key]) == .main else { continue }
            base["idb:" + key] = mainText
            guard mainText != ownText else { continue }
            put[key] = mainRecord.value
            previous[key] = own.records[key]?.string ?? NSNull()
        }
        guard !put.isEmpty else { return 0 }
        // Only the replaced values are kept: the rest of this database can hold the profile's sign-in keys.
        try backup.saveValues(previous, as: "Interface/\(profileID)-IndexedDB.json")
        try target.write(put, into: own)
        return put.count
    }

    /// The merged sidebar store to write, or `nil` if the profile's is already right.
    private func mergeSidebar(main: String?, own: String?, base: inout [String: String],
                              mainScope: String?, scope: String?) -> String? {
        guard let main, let mainStore = Self.object(main), let mainState = mainStore["state"] as? [String: Any] else { return nil }
        let ownStore = own.flatMap(Self.object) ?? [:]
        // Another store version means another layout; the app migrates its own data, so the two aren't mixed.
        if own != nil, Self.canonical(ownStore["version"] ?? NSNull()) != Self.canonical(mainStore["version"] ?? NSNull()) {
            return nil
        }
        let ownState = ownStore["state"] as? [String: Any] ?? [:]
        var state = ownState
        var wanted = mainState.filter { !Self.isOwnSidebarField($0.key) }
        wanted[Self.groupsField] = nil
        if let mainScope, let scope, let groups = (mainState[Self.groupsField] as? [String: Any])?[mainScope] {
            var mine = ownState[Self.groupsField] as? [String: Any] ?? [:]
            mine[scope] = groups
            wanted[Self.groupsField] = mine
        }
        for (field, mainValue) in wanted {
            let key = "\(Self.sidebarKey)/\(field)"
            let mainText = Self.canonical(mainValue), ownText = ownState[field].map(Self.canonical) ?? Self.missing
            if Self.resolve(own: ownText, main: mainText, base: base[key]) == .main {
                state[field] = mainValue
                base[key] = mainText
            }
        }
        guard own == nil || !NSDictionary(dictionary: state).isEqual(to: ownState) else { return nil }
        var store = mainStore
        store["state"] = state
        guard let data = try? JSONSerialization.data(withJSONObject: store, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func isOwnSidebarField(_ field: String) -> Bool {
        ownSidebarFields.contains(field) || field.hasSuffix("ByOrg") || field.hasSuffix("ScopeKey")
            || (field.hasSuffix("ByScope") && field != groupsField)
    }

    enum Side { case main, own }

    /// Three-way choice against `base`, the value both sides last agreed on (`nil` if never recorded).
    /// Only a change made on the profile's side alone is kept.
    static func resolve(own: String, main: String, base: String?) -> Side {
        guard let base, own != base else { return .main }
        return main == base ? .own : .main
    }

    /// `account/organization`, the key Claude files per-account sidebar state under.
    static func scope(in items: [String: String], account: String, dataDir: URL) -> String? {
        if let store = items[sidebarKey].flatMap(object), let state = store["state"] as? [String: Any],
           let key = state["lastSidebarScopeKey"] as? String, key.hasPrefix(account + "/") {
            return key
        }
        return DesktopData.organizationID(in: dataDir, accountID: account).map { "\(account)/\($0)" }
    }

    /// What a value means, without the bookkeeping Claude adds to `LSS-` entries (the writing tab and time).
    static func comparable(_ value: String) -> String {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) else { return value }
        if let wrapper = parsed as? [String: Any], wrapper["timestamp"] != nil, let inner = wrapper["value"] {
            return canonical(inner)
        }
        return canonical(parsed)
    }

    static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func readState(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }

    static func writeState(_ state: [String: String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
