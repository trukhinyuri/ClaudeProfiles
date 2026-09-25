import ClaudeUnlimitedKit
import SwiftUI

@MainActor
final class AddProfileForm: ObservableObject {
    @Published var email = "" { didSet { if !labelEdited { label = suggestedLabel } } }
    @Published var label = ""
    @Published var color: String
    var labelEdited = false
    let taken: Set<String>

    init(taken: Set<String>) {
        self.taken = taken
        self.color = Profile.palette[taken.count % Profile.palette.count]
    }

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    var suggestedLabel: String { trimmedEmail.isEmpty ? "" : Profile.suggestedLabel(for: trimmedEmail, taken: taken) }
    var labelIsTaken: Bool { taken.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
    var isValid: Bool { Profile.isValidEmail(trimmedEmail) && Profile.isValidLabel(label) && !labelIsTaken }
}

struct AddProfileSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var form: AddProfileForm
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _form = StateObject(wrappedValue: AddProfileForm(taken: model.existingLabels))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                DockIconPreview(label: form.label.isEmpty ? "NEW" : form.label.uppercased(), color: form.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a Subscription").font(.title3.weight(.semibold))
                    Text("A new Claude window opens with its own Dock icon. Sign in there with this account; the email code is entered right in that window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Email").gridColumnAlignment(.trailing)
                    TextField("you@example.com", text: $form.email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .onSubmit(create)
                }
                GridRow {
                    Text("Dock label")
                    HStack {
                        TextField("WORK", text: Binding(get: { form.label }, set: { form.label = String($0.uppercased().prefix(Profile.maxLabelLength)); form.labelEdited = true }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        if form.labelIsTaken {
                            Text("Already used").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                GridRow {
                    Text("Color")
                    HStack(spacing: 8) {
                        ForEach(Profile.palette, id: \.self) { hex in
                            Button { form.color = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: form.color == hex ? 2 : 0))
                                    .overlay(Circle().strokeBorder(Color(hex: hex), lineWidth: form.color == hex ? 1 : 0).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color \(hex)")
                        }
                    }
                }
            }

            Label("ClaudeUnlimited never sees your password, codes or tokens: you sign in inside the official Claude app.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create and Open", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.isValid)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func create() {
        guard form.isValid else { return }
        let (email, label, color) = (form.trimmedEmail, form.label, form.color)
        dismiss()
        model.create(email: email, label: label, color: color)
    }
}

/// Shows the Dock icon the new profile will get, drawn from the locally installed Claude app.
struct DockIconPreview: View {
    let label: String
    let color: String

    var body: some View {
        let base = NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
        Image(nsImage: IconRenderer.profileIcon(base: base, label: label, color: NSColor(hex: color)))
            .resizable()
            .interpolation(.high)
            .frame(width: 72, height: 72)
            .accessibilityLabel("Dock icon preview")
    }
}
