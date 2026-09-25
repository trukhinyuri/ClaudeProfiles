import AppKit
import ClaudeUnlimitedKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statuses: [ProfileStatus] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncChanges = 0
    @Published private(set) var syncError: String?
    @Published private(set) var registryError: String?
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var isAdding = false
    @Published var pendingRemoval: ProfileStatus?

    let manager: ProfileManager
    let isDemo = ProcessInfo.processInfo.environment["CLAUDE_UNLIMITED_DEMO"] == "1"
    private var refreshTimer: Timer?
    private var syncTimer: Timer?

    init() {
        let cli = Bundle.main.bundleURL.appending(path: "Contents/Helpers/claude-unlimited")
        manager = ProfileManager(cliPath: FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil)
        reload()
        // Documentation screenshots: CLAUDE_UNLIMITED_DEMO=1 shows sample data, …_DEMO_SHEET=1 opens "Add".
        guard !isDemo else {
            isAdding = ProcessInfo.processInfo.environment["CLAUDE_UNLIMITED_DEMO_SHEET"] == "1"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.setContentSize(NSSize(width: 900, height: 530))
            }
            return
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        Task.detached { [manager] in try? manager.refresh() }
        syncNow()
    }

    var profiles: [ProfileStatus] { statuses }
    var existingLabels: Set<String> { Set(statuses.compactMap { $0.profile?.label }) }

    /// The signed-in profile with the most weekly headroom, if there is a meaningful choice to make.
    /// Profiles out of five-hour quota or with usage data older than a week are not suggested.
    var suggestedID: String? {
        let now = Date()
        let candidates = statuses.filter { status in
            guard status.isSignedIn, let usage = status.usage, let week = usage.week, week < 100,
                  now.timeIntervalSince(usage.sampledAt) < 7 * 86_400 else { return false }
            return usage.isFiveHourStale(now: now) || (usage.fiveHour ?? 0) < 100
        }
        guard candidates.count > 1 else { return nil }
        return candidates.min { ($0.usage?.week ?? 100) < ($1.usage?.week ?? 100) }?.id
    }

    func reload() {
        if isDemo { statuses = DemoData.statuses; lastSync = Date().addingTimeInterval(-14); return }
        let manager = manager
        Task.detached {
            let fresh = manager.statuses()
            let problem = manager.registryError
            await MainActor.run {
                if self.statuses != fresh { self.statuses = fresh }
                if self.registryError != problem { self.registryError = problem }
            }
        }
    }

    func syncNow() {
        guard !isDemo else { return }
        let manager = manager
        Task.detached {
            do {
                // nil: the CLI or a launcher is syncing right now; the next tick will catch up.
                guard let report = try manager.syncSessions() else { return }
                await MainActor.run {
                    self.lastSync = Date()
                    self.lastSyncChanges = report.changes
                    self.syncError = nil
                }
            } catch {
                await MainActor.run { self.syncError = error.localizedDescription }
            }
        }
    }

    func open(_ status: ProfileStatus) {
        guard !isDemo else { return }
        let manager = manager
        run(status.isRunning ? nil : "Opening \(status.isMain ? "Claude" : "Claude \(status.label)")…") {
            if let id = status.profile?.id { try await manager.open(id) } else { try await manager.openMain() }
        }
    }

    func create(email: String, label: String, color: String) {
        let manager = manager
        run("Creating Claude \(label)…") {
            let profile = try await Task.detached { try manager.create(label: label, email: email, color: color) }.value
            try await manager.open(profile.id)
        }
    }

    func remove(_ status: ProfileStatus) {
        guard let id = status.profile?.id else { return }
        let manager = manager
        run("Removing Claude \(status.label)…") { try await manager.remove(id) }
    }

    func revealLauncher(_ status: ProfileStatus) {
        guard let profile = status.profile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([manager.paths.launcher(for: profile)])
    }

    private func run(_ message: String?, _ work: @escaping @Sendable () async throws -> Void) {
        busyMessage = message
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
            busyMessage = nil
            reload()
        }
    }
}

enum DemoData {
    static var statuses: [ProfileStatus] {
        let now = Date()
        return [
            ProfileStatus(profile: nil, accountID: "demo-main", email: "alex@example.com",
                          usage: Usage(fiveHour: 64, week: 92, sampledAt: now.addingTimeInterval(-600)), isRunning: true),
            ProfileStatus(profile: Profile(id: "work", label: "WORK", email: "alex@acme.dev", color: "#1971C2"),
                          accountID: "demo-work", email: "alex@acme.dev",
                          usage: Usage(fiveHour: 12, week: 31, sampledAt: now.addingTimeInterval(-300)), isRunning: true),
            ProfileStatus(profile: Profile(id: "lab", label: "LAB", email: "alex.lab@example.org", color: "#2F9E44"),
                          accountID: "demo-lab", email: "alex.lab@example.org",
                          usage: Usage(fiveHour: 0, week: 58, sampledAt: now.addingTimeInterval(-7200)), isRunning: false),
            ProfileStatus(profile: Profile(id: "team", label: "TEAM", email: "alex@team.example", color: "#7048E8"),
                          accountID: nil, email: nil, usage: nil, isRunning: true),
        ]
    }
}
