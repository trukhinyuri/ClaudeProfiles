import ClaudeProfilesKit
import SwiftUI

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

struct ProfileBadge: View {
    let label: String
    let color: String
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color(hex: color).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(label)
                    .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, size * 0.1)
            }
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

struct UsageMeter: View {
    let title: String
    let percent: Int?
    var isStale = false

    private var tint: Color {
        guard let percent, !isStale else { return .secondary }
        return percent >= 90 ? .red : percent >= 70 ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: isStale ? 0 : proxy.size.width * CGFloat(min(percent ?? 0, 100)) / 100)
                }
            }
            .frame(height: 5)
            Text(isStale ? "reset" : percent.map { "\($0)%" } ?? "–")
                .monospacedDigit()
                .foregroundStyle(isStale ? .secondary : .primary)
                .frame(width: 36, alignment: .trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(isStale ? "reset" : percent.map { "\($0) percent" } ?? "unknown")
    }
}

struct UsageColumn: View {
    let status: ProfileStatus

    var body: some View {
        if let usage = status.usage, status.isSignedIn {
            VStack(alignment: .leading, spacing: 5) {
                UsageMeter(title: "5-hour", percent: usage.fiveHour, isStale: usage.isFiveHourStale())
                UsageMeter(title: "Weekly", percent: usage.week)
                Text("Updated \(usage.sampledAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 56)
            }
        } else {
            Text(status.isSignedIn ? "Usage appears after the first message" : "Usage appears after sign-in")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProfileRow: View {
    let status: ProfileStatus
    let isSuggested: Bool
    @ObservedObject var model: AppModel

    private var title: String {
        status.email ?? status.profile?.email ?? (status.isSignedIn ? "Signed in" : "Not signed in")
    }

    private var subtitle: String {
        (status.isMain ? "Main Claude app" : "Claude \(status.label)") + (status.isRunning ? " · Open" : " · Closed")
    }

    var body: some View {
        HStack(spacing: 14) {
            ProfileBadge(label: status.label, color: status.color)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if isSuggested {
                        Text("Most headroom")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                            .help("Lowest weekly usage among your signed-in subscriptions")
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.isRunning ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !status.isSignedIn {
                    Label("Sign in inside the Claude \(status.label) window", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .help("While this window signs in, sign-in links from your browser open here instead of in the main Claude app.")
                } else if status.isUnexpectedAccount, let expected = status.profile?.email {
                    Label("Signed in as a different account than \(expected)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            UsageColumn(status: status)
                .frame(width: 210)

            HStack(spacing: 4) {
                Button(status.isRunning ? "Show" : "Open") { model.open(status) }
                    .frame(width: 64)
                Menu {
                    if !status.isMain {
                        Button("Show Launcher in Finder") { model.revealLauncher(status) }
                        Divider()
                        Button("Remove Subscription…", role: .destructive) { model.pendingRemoval = status }
                    } else {
                        Text("The main Claude app can’t be removed")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct EmptyHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your next subscription").font(.body.weight(.semibold))
                Text("Each one gets its own Claude window and a labeled Dock icon, so you always know which account you are in. Your Claude Code sessions show up in every window, so you can pick up any of them in whichever subscription you choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.separator))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.statuses) { status in
                        ProfileRow(status: status, isSuggested: status.id == model.suggestedID, model: model)
                    }
                    if model.statuses.count == 1 { EmptyHint() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 380, idealHeight: 580)
        .sheet(isPresented: $model.isAdding) { AddProfileSheet(model: model) }
        .confirmationDialog(
            "Remove \(model.pendingRemoval.map { $0.email ?? "Claude \($0.label)" } ?? "")?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval
        ) { status in
            Button("Remove", role: .destructive) { model.remove(status) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its window closes and its app copy and sign-in move to the Trash. Your Claude Code sessions stay available in every other window; Cowork sessions started in it move to the Trash with it.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Subscriptions").font(.title2.weight(.semibold))
                Text("Every subscription runs in its own Claude window with a labeled Dock icon. Sessions, settings and skills are shared.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.isAdding = true
            } label: {
                Label("Add Subscription", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(message)
            } else if let problem = model.registryError ?? model.syncError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem).lineLimit(2).textSelection(.enabled)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                if model.statuses.count < 2 {
                    Text("Sessions will be shared as soon as you add a subscription")
                } else if let last = model.lastSync {
                    Text("Sessions shared across \(model.statuses.count) windows · synced \(last, format: .relative(presentation: .named))")
                } else {
                    Text("Sharing sessions…")
                }
            }
            Spacer()
            Link(destination: URL(string: "https://github.com/trukhinyuri/ClaudeProfiles#staying-within-anthropics-terms")!) {
                Label("Fair use", systemImage: "checkmark.shield")
            }
            .help("How Claude Profiles stays within Anthropic’s terms")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }
}
