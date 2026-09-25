import Foundation

/// Gives a profile the main app's local setup before its window starts: desktop extensions, MCP servers,
/// tool toggles, SSH hosts and app preferences. The main app is the source; a profile keeps only settings
/// the main app doesn't have. Sign-in data (`config.json`, cookies) is never touched.
///
/// Run it only while the profile's window is closed: Claude writes these files back when it quits.
public struct SettingsSync: Sendable {
    /// Files and folders copied as they are.
    static let copied = ["Claude Extensions", "Claude Extensions Settings", "extensions-installations.json", "ssh_configs.json"]
    /// JSON files merged key by key, main app first.
    static let merged = ["claude_desktop_config.json", "mcp-user-tool-toggles.json"]

    public let paths: Paths
    private var fm: FileManager { .default }

    public init(paths: Paths) { self.paths = paths }

    /// - Returns: how many files or folders changed.
    @discardableResult
    public func run(into dataDir: URL, now: Date = Date()) throws -> Int {
        let source = paths.mainDataDir
        let backup = Backup(paths: paths, now: now)
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
        for name in Self.merged {
            let from = source.appending(path: name), to = dataDir.appending(path: name)
            guard let main = Self.readJSON(from) else { continue }
            let current = Self.readJSON(to) ?? [:]
            let result = Self.merge(current, main)
            guard !NSDictionary(dictionary: result).isEqual(to: current) else { continue }
            if fm.fileExists(atPath: to.path) { _ = try backup.save(to) }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: to, options: .atomic)
            changed += 1
        }
        return changed
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
