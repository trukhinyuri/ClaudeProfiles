import Foundation

/// Lets a profile window receive its own sign-in.
///
/// Claude Desktop's Google sign-in finishes in the browser and comes back through a `claude://` link.
/// macOS delivers that link to the registered copy of Claude, which is normally the main app, and the main
/// app ignores a sign-in it didn't start. While a profile signs in, only that profile's app copy stays
/// registered with Launch Services, so the link reaches the window that asked for it. Afterwards the main
/// app is registered again. The link itself is never read: it goes straight from macOS to Claude.
public struct SignInRouting: Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var profileID: String
        public var startedAt: Date
    }

    /// Longest time the main app stays unregistered if a sign-in is abandoned.
    public static let timeout: TimeInterval = 15 * 60
    /// Time a profile window gets to start before an unfinished sign-in is dropped.
    public static let launchGrace: TimeInterval = 60

    public let paths: Paths
    /// Registers (`true`) or unregisters (`false`) an app bundle with Launch Services.
    let register: @Sendable (URL, Bool) -> Void

    public init(paths: Paths) {
        self.init(paths: paths) { app, on in
            ProfileManager.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                               [on ? "-f" : "-u", app.path])
        }
    }

    init(paths: Paths, register: @escaping @Sendable (URL, Bool) -> Void) {
        self.paths = paths
        self.register = register
    }

    var stateFile: URL { paths.stateDir.appending(path: "sign-in.json") }

    public var state: State? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    /// Sends `claude://` links to `profileID`'s app copy until `end()`.
    public func begin(profileID: String, allProfileIDs: [String], now: Date = Date()) throws {
        register(paths.claudeApp, false)
        for id in allProfileIDs where id != profileID {
            register(paths.engine(for: id), false)
        }
        register(paths.engine(for: profileID), true)
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(State(profileID: profileID, startedAt: now)).write(to: stateFile, options: .atomic)
    }

    /// Gives `claude://` links back to the main app. App copies are unregistered so they never outrank it.
    public func end(allProfileIDs: [String]) {
        for id in allProfileIDs {
            register(paths.engine(for: id), false)
        }
        register(paths.claudeApp, true)
        try? FileManager.default.removeItem(at: stateFile)
    }

    /// Whether a sign-in in progress is over: done, abandoned, or its window never started.
    public static func isFinished(_ state: State, signedIn: Bool, running: Bool, profileExists: Bool, now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(state.startedAt)
        return !profileExists || signedIn || elapsed > timeout || (!running && elapsed > launchGrace)
    }
}
