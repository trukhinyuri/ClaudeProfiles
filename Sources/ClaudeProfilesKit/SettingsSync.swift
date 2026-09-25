import Foundation

/// Gives a profile the main app's local setup before its window starts: desktop extensions, MCP servers,
/// tool toggles, SSH hosts, app preferences and appearance. The main app is the source; a profile keeps only
/// settings the main app doesn't have. Sign-in data (tokens in `config.json`, cookies) is never copied.
///
/// Run it only while the profile's window is closed: Claude writes these files back when it quits.
public struct SettingsSync: Sendable {
    /// Files and folders copied as they are.
    static let copied = ["Claude Extensions", "Claude Extensions Settings", "extensions-installations.json",
                         "ssh_configs.json", "claude-ssh-remote"]
    /// Claude Code builds the main app has downloaded, one folder per version. Cloning them spares a profile the download.
    static let builds = "claude-code"
    /// Scheduled tasks run only in the main app; with these on, every window would run each task.
    static let schedulerPreferences = ["ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled", "wakeSchedulerEnabled"]
    /// The only `config.json` keys copied; the rest of that file is sign-in and per-window state.
    static let appearanceKeys = ["userThemeMode", "windowControlsZoomFactor", "locale"]

    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) { self.paths = paths }

    /// - Returns: how many files or folders changed.
    @discardableResult
    public func run(into dataDir: URL, now: Date = Date()) throws -> Int {
        let source = paths.mainDataDir
        let backup = Backup(paths: paths, now: now)
        let mainAccount = DesktopData.accountID(in: source)
        let account = DesktopData.accountID(in: dataDir)
        var changed = 0

        for name in Self.copied {
            let from = source.appending(path: name), to = dataDir.appending(path: name)
            guard fm.fileExists(atPath: from.path), !fm.contentsEqual(atPath: from.path, andPath: to.path) else { continue }
            if fm.fileExists(atPath: to.path) {
                _ = try backup.save(to)
                try fm.trashItem(at: to, resultingItemURL: nil)
            }
            try fm.copyItem(at: from, to: to)   // an APFS clone, so extensions take no extra space
            changed += 1
        }

        changed += try copyBuilds(into: dataDir)

        if try mergeJSON("claude_desktop_config.json", into: dataDir, backup: backup, adjust: { config, current in
            var preferences = config["preferences"] as? [String: Any] ?? [:]
            for key in Self.schedulerPreferences { preferences[key] = false }
            // Interface settings here are shared by InterfaceSync, per account and keeping changes made only in the profile.
            if var prefs = preferences["epitaxyPrefs"] as? [String: Any] {
                let own = (current["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any] ?? [:]
                prefs = prefs.filter { !InterfaceSync.sharesPref($0.key) }
                for (key, value) in own where InterfaceSync.sharesPref(key) { prefs[key] = value }
                preferences["epitaxyPrefs"] = prefs
            }
            config["preferences"] = preferences
        }) { changed += 1 }

        // Tool toggles are kept per account; the profile's account gets the ones chosen in the main app.
        if try mergeJSON("mcp-user-tool-toggles.json", into: dataDir, backup: backup, adjust: { toggles, _ in
            guard let mainAccount, let account, var owners = toggles["owners"] as? [String: Any],
                  let chosen = owners[mainAccount] else { return }
            owners[account] = chosen
            toggles["owners"] = owners
        }) { changed += 1 }

        if try copyAppearance(into: dataDir) { changed += 1 }
        return changed
    }

    /// Copies Claude Code versions the profile doesn't have yet. Only finished downloads (with `.verified`) are
    /// copied, under a temporary name first, so a profile never sees half a build.
    private func copyBuilds(into dataDir: URL) throws -> Int {
        let from = paths.mainDataDir.appending(path: Self.builds, directoryHint: .isDirectory)
        let to = dataDir.appending(path: Self.builds, directoryHint: .isDirectory)
        var copied = 0
        for version in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where !version.hasPrefix(".") {
            let build = from.appending(path: version, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: build.appending(path: ".verified").path),
                  !fm.fileExists(atPath: to.appending(path: version).path) else { continue }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            let partial = to.appending(path: ".\(version)-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.copyItem(at: build, to: partial)
            try fm.moveItem(at: partial, to: to.appending(path: version, directoryHint: .isDirectory))
            copied += 1
        }
        return copied
    }

    /// Merges `name` from the main app into the profile, applies `adjust` (which also gets the profile's
    /// current contents), and writes it if anything changed.
    private func mergeJSON(_ name: String, into dataDir: URL, backup: Backup,
                           adjust: (inout [String: Any], [String: Any]) -> Void) throws -> Bool {
        let from = paths.mainDataDir.appending(path: name), to = dataDir.appending(path: name)
        guard let main = Self.readJSON(from) else { return false }
        let current = Self.readJSON(to) ?? [:]
        var result = Self.merge(current, main)
        adjust(&result, current)
        guard !NSDictionary(dictionary: result).isEqual(to: current) else { return false }
        if fm.fileExists(atPath: to.path) { _ = try backup.save(to) }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: to, options: .atomic)
        return true
    }

    /// Copies theme, zoom and language into the profile's `config.json`, leaving everything else in it untouched.
    /// That file also holds the profile's sign-in, so it is edited in place and never backed up or copied.
    private func copyAppearance(into dataDir: URL) throws -> Bool {
        let to = dataDir.appending(path: "config.json")
        guard let main = Self.readJSON(paths.mainDataDir.appending(path: "config.json")),
              var config = Self.readJSON(to) else { return false }
        let before = NSDictionary(dictionary: config)
        for key in Self.appearanceKeys {
            if let value = main[key] { config[key] = value }
        }
        guard !before.isEqual(to: config) else { return false }
        let permissions = (try? fm.attributesOfItem(atPath: to.path)[.posixPermissions]) ?? NSNumber(value: 0o600)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: to, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: to.path)
        return true
    }

    /// `main` wins; nested objects such as `preferences` or per-account maps are merged the same way.
    static func merge(_ profile: [String: Any], _ main: [String: Any]) -> [String: Any] {
        var result = profile
        for (key, value) in main {
            if let inner = value as? [String: Any], let own = profile[key] as? [String: Any], key != "mcpServers" {
                result[key] = merge(own, inner)
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
