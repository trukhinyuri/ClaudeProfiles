import ClaudeProfilesKit
import SwiftUI

@main
struct ClaudeProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Claude Profiles", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Subscription…") { model.isAdding = true }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Share Sessions Now") { model.syncNow() }.keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
    }
}

/// Keeps session sharing running in the menu bar after the window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.statuses) { status in
            Button(menuTitle(for: status)) { model.open(status) }
        }
        Divider()
        Button("Open Claude Profiles") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Add Subscription…") {
            openWindow(id: "main")
            NSApp.activate()
            model.isAdding = true
        }
        Button("Share Sessions Now") { model.syncNow() }
        Divider()
        Button("Quit Claude Profiles") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func menuTitle(for status: ProfileStatus) -> String {
        let name = status.isMain ? "Claude" : "Claude \(status.label)"
        let who = status.email ?? (status.isSignedIn ? "signed in" : "not signed in")
        var usage = ""
        if let week = status.usage?.week { usage = " · \(week)% of week" }
        return "\(status.isRunning ? "●" : "○")  \(name) — \(who)\(usage)"
    }
}
