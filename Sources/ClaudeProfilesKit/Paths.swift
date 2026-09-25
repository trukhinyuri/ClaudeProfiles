import Foundation

/// Every location Claude Profiles reads or writes. Injected everywhere so tests can run in a sandbox.
public struct Paths: Sendable, Equatable {
    /// The user's home directory.
    public var home: URL
    /// The official Claude Desktop app. Profiles run APFS clones of it.
    public var claudeApp: URL

    public init(home: URL, claudeApp: URL) {
        self.home = home
        self.claudeApp = claudeApp
    }

    public static var standard: Paths {
        Paths(home: FileManager.default.homeDirectoryForCurrentUser,
              claudeApp: URL(fileURLWithPath: "/Applications/Claude.app"))
    }

    public var applicationSupport: URL { home.appending(path: "Library/Application Support", directoryHint: .isDirectory) }

    /// Data directory of the main Claude Desktop app (the one you open from /Applications).
    public var mainDataDir: URL { applicationSupport.appending(path: "Claude", directoryHint: .isDirectory) }

    /// Claude Profiles's own state: profile registry and backups.
    public var stateDir: URL { applicationSupport.appending(path: "Claude Profiles", directoryHint: .isDirectory) }
    public var registryFile: URL { stateDir.appending(path: "profiles.json") }
    public var backupsDir: URL { stateDir.appending(path: "Backups", directoryHint: .isDirectory) }

    /// Each profile's Claude Desktop data (sign-in, windows, caches) lives in its own directory here.
    public var profilesDir: URL { stateDir.appending(path: "Profiles", directoryHint: .isDirectory) }
    public func dataDir(for id: String) -> URL { profilesDir.appending(path: id, directoryHint: .isDirectory) }

    /// Launchers are visible in Finder, Spotlight and Launchpad and can be kept in the Dock.
    public var launchersDir: URL { home.appending(path: "Applications/Claude Profiles", directoryHint: .isDirectory) }
    public func launcher(for profile: Profile) -> URL { launchersDir.appending(path: "Claude \(profile.label).app", directoryHint: .isDirectory) }

    /// Engines are the APFS clones of Claude.app that actually run. Hidden: open them via launchers.
    public var enginesDir: URL { launchersDir.appending(path: ".engines", directoryHint: .isDirectory) }
    public func engine(for id: String) -> URL { enginesDir.appending(path: "Claude \(id).app", directoryHint: .isDirectory) }
}
