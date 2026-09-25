import AppKit
import Darwin

public enum ProfileError: LocalizedError, Equatable {
    case claudeNotInstalled(String)
    case invalidLabel
    case invalidEmail
    case duplicateLabel(String)
    case notFound(String)
    case cloneFailed(String)

    public var errorDescription: String? {
        switch self {
        case .claudeNotInstalled(let path): "Claude Desktop is not installed at \(path). Install it from claude.ai/download."
        case .invalidLabel: "Use 1–\(Profile.maxLabelLength) letters, digits, “-” or “_” for the label."
        case .invalidEmail: "That doesn’t look like an email address."
        case .duplicateLabel(let label): "A profile labeled “\(label)” already exists."
        case .notFound(let id): "No profile “\(id)”."
        case .cloneFailed(let reason): "Couldn’t create the app copy: \(reason)"
        }
    }
}

/// What the UI and CLI show for one Claude window: the main app or a profile.
public struct ProfileStatus: Identifiable, Equatable, Sendable {
    public var profile: Profile?          // nil for the main Claude app
    public var accountID: String?
    public var email: String?
    public var usage: Usage?
    public var isRunning: Bool

    public init(profile: Profile?, accountID: String?, email: String?, usage: Usage?, isRunning: Bool) {
        self.profile = profile
        self.accountID = accountID
        self.email = email
        self.usage = usage
        self.isRunning = isRunning
    }

    public var id: String { profile?.id ?? "main" }
    public var isMain: Bool { profile == nil }
    public var isSignedIn: Bool { accountID != nil }
    public var label: String { profile?.label ?? "MAIN" }
    public var color: String { profile?.color ?? Profile.mainColor }
    /// Signed in with a different account than the one the profile was created for.
    public var isUnexpectedAccount: Bool {
        guard let expected = profile?.email, let email else { return false }
        return expected.caseInsensitiveCompare(email) != .orderedSame
    }
}

/// Creates, opens and removes profiles. Every operation is local to this Mac.
public final class ProfileManager: @unchecked Sendable {
    public let paths: Paths
    public let registry: ProfileRegistry
    public let signInRouting: SignInRouting
    /// The `claude-profiles` executable that launchers call. `nil` makes launchers open the engine directly.
    public var cliPath: URL?
    private var fm: FileManager { .default }
    /// Serializes changes to the registry and to engines within this process; `FileLock` does it across processes.
    private let lock = NSRecursiveLock()
    private var emailCache: [String: (account: String, email: String?, checkedAt: Date)] = [:]

    public init(paths: Paths = .standard, cliPath: URL? = nil) {
        self.paths = paths
        self.registry = ProfileRegistry(paths: paths)
        self.signInRouting = SignInRouting(paths: paths)
        self.cliPath = cliPath
    }

    /// Profiles from the registry; empty if it is missing or damaged (see `registryError`).
    public var profiles: [Profile] { (try? registry.load()) ?? [] }

    /// Why the registry couldn't be read, if it couldn't. Changes are refused until it is fixed.
    public var registryError: String? {
        do { _ = try registry.load(); return nil } catch {
            return "Can’t read \(paths.registryFile.path): \(error.localizedDescription). A backup is at profiles.json.bak."
        }
    }

    public var dataDirs: [URL] {
        [paths.mainDataDir] + profiles.map { paths.dataDir(for: $0.id) }.filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: Status

    public func statuses() -> [ProfileStatus] {
        let running = runningBundlePaths()
        let main = status(profile: nil, dataDir: paths.mainDataDir, running: running.contains(paths.claudeApp.standardizedFileURL.path))
        let all = [main] + profiles.map { profile in
            status(profile: profile, dataDir: paths.dataDir(for: profile.id),
                   running: running.contains(paths.engine(for: profile.id).standardizedFileURL.path))
        }
        finishSignInIfDone(all)
        return all
    }

    /// Returns `claude://` links to the main app once the profile signing in is done with them.
    private func finishSignInIfDone(_ statuses: [ProfileStatus]) {
        guard let state = signInRouting.state else { return }
        let target = statuses.first { $0.profile?.id == state.profileID }
        if SignInRouting.isFinished(state, signedIn: target?.isSignedIn ?? false, running: target?.isRunning ?? false,
                                    profileExists: target != nil) {
            signInRouting.end(allProfileIDs: profiles.map(\.id))
        }
    }

    /// The profile whose window currently receives sign-in links, if any.
    public var profileSigningIn: String? { signInRouting.state?.profileID }

    private func status(profile: Profile?, dataDir: URL, running: Bool) -> ProfileStatus {
        let account = DesktopData.accountID(in: dataDir)
        return ProfileStatus(profile: profile, accountID: account,
                             email: account.flatMap { email(in: dataDir, accountID: $0) },
                             usage: DesktopData.usage(in: dataDir), isRunning: running)
    }

    /// Scanning IndexedDB is expensive, so a found email is kept until the account changes
    /// and a miss is retried at most once a minute.
    private func email(in dataDir: URL, accountID: String) -> String? {
        let key = dataDir.path
        if let cached = lock.withLock({ emailCache[key] }), cached.account == accountID,
           cached.email != nil || Date().timeIntervalSince(cached.checkedAt) < 60 {
            return cached.email
        }
        let found = DesktopData.email(in: dataDir, accountID: accountID)
        lock.withLock { emailCache[key] = (accountID, found, Date()) }
        return found
    }

    /// Bundle paths of running Claude Desktop processes (main app and engines share a bundle identifier).
    func runningBundlePaths() -> Set<String> {
        Set(claudeProcesses().compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    func claudeProcesses() -> [NSRunningApplication] {
        guard let identifier = Bundle(url: paths.claudeApp)?.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    }

    public var isAnyClaudeRunning: Bool { !claudeProcesses().isEmpty }

    // MARK: Create

    @discardableResult
    public func create(label rawLabel: String, email rawEmail: String?, color: String? = nil) throws -> Profile {
        guard fm.fileExists(atPath: paths.claudeApp.path) else { throw ProfileError.claudeNotInstalled(paths.claudeApp.path) }
        let label = rawLabel.trimmingCharacters(in: .whitespaces).uppercased()
        guard Profile.isValidLabel(label) else { throw ProfileError.invalidLabel }
        let email = rawEmail?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let email, !Profile.isValidEmail(email) { throw ProfileError.invalidEmail }

        lock.lock(); defer { lock.unlock() }
        var all = try registry.load()
        guard !all.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
            throw ProfileError.duplicateLabel(label)
        }
        var id = Profile.slug(for: label)
        let base = id
        var n = 2
        while all.contains(where: { $0.id == id }) || fm.fileExists(atPath: paths.dataDir(for: id).path) {
            id = "\(base)-\(n)"; n += 1
        }
        let profile = Profile(id: id, label: label, email: email,
                              color: color ?? Profile.palette[all.count % Profile.palette.count])
        try fm.createDirectory(at: paths.dataDir(for: id), withIntermediateDirectories: true)
        try buildEngine(for: profile)
        try buildLauncher(for: profile)
        all.append(profile)
        try registry.save(all)
        return profile
    }

    // MARK: Open

    /// Brings the profile's window forward, starting it first if needed.
    public func open(_ id: String) async throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        let engine = paths.engine(for: profile.id)
        if DesktopData.accountID(in: paths.dataDir(for: profile.id)) == nil {
            try signInRouting.begin(profileID: profile.id, allProfileIDs: profiles.map(\.id))
        }
        if let running = claudeProcesses().first(where: { $0.bundleURL?.standardizedFileURL == engine.standardizedFileURL }) {
            running.activate()
            return
        }
        try lock.withLock {
            if !fm.fileExists(atPath: engine.path) || engineIsOutdated(profile.id) {
                try buildEngine(for: profile)
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=\(paths.dataDir(for: profile.id).path)"]
        _ = try await NSWorkspace.shared.openApplication(at: engine, configuration: configuration)
    }

    public func openMain() async throws {
        _ = try await NSWorkspace.shared.openApplication(at: paths.claudeApp, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Remove

    /// Quits the profile's window and moves its app copy and data (including its sign-in) to the Trash.
    /// Sessions stay available in every other profile.
    public func remove(_ id: String) async throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
        let engine = paths.engine(for: id).standardizedFileURL
        let running = claudeProcesses().filter { $0.bundleURL?.standardizedFileURL == engine }
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

        // Share cards of sessions started in this window moments ago before its data goes away.
        _ = try? syncSessions()

        try lock.withLock {
            for url in [paths.launcher(for: profile), paths.engine(for: id), paths.dataDir(for: id)] where fm.fileExists(atPath: url.path) {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
            try registry.save(try registry.load().filter { $0.id != id })
        }
        if signInRouting.state?.profileID == id { signInRouting.end(allProfileIDs: profiles.map(\.id)) }
    }

    // MARK: Maintenance

    /// Rebuilds app copies left behind by a Claude Desktop update and launchers that point to a moved CLI.
    /// Copies that are running are left alone until next launch.
    public func refresh() throws {
        let running = runningBundlePaths()
        for profile in profiles {
            let engine = paths.engine(for: profile.id)
            try lock.withLock {
                if !running.contains(engine.standardizedFileURL.path), !fm.fileExists(atPath: engine.path) || engineIsOutdated(profile.id) {
                    try buildEngine(for: profile)
                }
            }
            if launcherScript(for: profile) != (try? String(contentsOf: launcherExecutable(for: profile), encoding: .utf8)) {
                try buildLauncher(for: profile)
            }
        }
    }

    /// Shares Claude Code sessions across all profiles.
    /// - Returns: `nil` if another sync (from the app or the CLI) is already running.
    @discardableResult
    public func syncSessions() throws -> SessionSync.Report? {
        try FileLock.withLock(paths.stateDir.appending(path: "sync.lock"), blocking: false) {
            try SessionSync(paths: paths, dataDirs: dataDirs).run(propagateDeletions: !isAnyClaudeRunning)
        }
    }

    // MARK: Building

    /// Reads the version from disk every time; `Bundle` caches Info.plist for the life of the process.
    static func version(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleVersion"] as? String
    }

    func engineIsOutdated(_ id: String) -> Bool {
        let installed = Self.version(of: paths.claudeApp)
        return installed != nil && installed != Self.version(of: paths.engine(for: id))
    }

    /// Clones Claude.app with APFS copy-on-write (near-zero disk use) and gives the clone a labeled Finder icon.
    /// The icon is the only change: it adds a Finder icon file, and Anthropic's code signature still verifies.
    func buildEngine(for profile: Profile) throws {
        try lock.withLock {
            _ = try FileLock.withLock(paths.stateDir.appending(path: "engines.lock"), blocking: true) {
                try cloneEngine(for: profile)
            }
        }
    }

    private func cloneEngine(for profile: Profile) throws {
        let engine = paths.engine(for: profile.id)
        try fm.createDirectory(at: paths.enginesDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: engine.path) { try fm.removeItem(at: engine) }
        if clonefile(paths.claudeApp.path, engine.path, 0) != 0 {
            let reason = String(cString: strerror(errno))
            do { try fm.copyItem(at: paths.claudeApp, to: engine) } catch { throw ProfileError.cloneFailed("\(reason); \(error.localizedDescription)") }
        }
        NSWorkspace.shared.setIcon(icon(for: profile), forFile: engine.path, options: [])
    }

    func icon(for profile: Profile) -> NSImage {
        IconRenderer.profileIcon(base: NSWorkspace.shared.icon(forFile: paths.claudeApp.path),
                                 label: profile.label, color: NSColor(hex: profile.color))
    }

    func launcherExecutable(for profile: Profile) -> URL {
        paths.launcher(for: profile).appending(path: "Contents/MacOS/launch")
    }

    func launcherScript(for profile: Profile) -> String {
        let engine = paths.engine(for: profile.id).path
        let dataDir = paths.dataDir(for: profile.id).path
        var script = "#!/bin/sh\n# Generated by Claude Profiles. Opens Claude with the \(profile.label) profile.\n"
        if let cli = cliPath?.path {
            script += "if [ -x \(shellQuote(cli)) ]; then exec \(shellQuote(cli)) open \(shellQuote(profile.id)); fi\n"
        }
        script += "exec /usr/bin/open -n -a \(shellQuote(engine)) --args \(shellQuote("--user-data-dir=" + dataDir))\n"
        return script
    }

    /// A tiny app bundle that opens the profile. It can live in the Dock and is found by Spotlight.
    func buildLauncher(for profile: Profile) throws {
        let app = paths.launcher(for: profile)
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)

        let executable = launcherExecutable(for: profile)
        try launcherScript(for: profile).write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try IconRenderer.icnsData(for: icon(for: profile)).write(to: contents.appending(path: "Resources/AppIcon.icns"))

        let info: [String: Any] = [
            "CFBundleIdentifier": "io.github.trukhinyuri.claudeprofiles.launcher.\(profile.id)",
            "CFBundleName": "Claude \(profile.label)",
            "CFBundleDisplayName": "Claude \(profile.label)",
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        Self.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        Self.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", app.path])
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// An advisory `flock(2)` lock shared by the app, the CLI and launchers.
enum FileLock {
    /// - Returns: the body's result, or `nil` if `blocking` is false and the lock is held elsewhere.
    static func withLock<T>(_ url: URL, blocking: Bool, _ body: () throws -> T) throws -> T? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | (blocking ? 0 : LOCK_NB)) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
