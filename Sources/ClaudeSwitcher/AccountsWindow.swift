import SwiftUI
import SwitcherCore

/// Form fields live in an ObservableObject: the Command Line Tools lack SwiftUI's `@State` macro plugin.
final class CaptureForm: ObservableObject {
    @Published var label = "Main"
    @Published var role: ProfileRole = .main
    @Published var includeDesktop = false
}

struct AccountsWindow: View {
    @ObservedObject var model: AppModel
    @StateObject private var form = CaptureForm()

    var body: some View {
        Form {
            Section("Saved accounts") {
                if model.state.profiles.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(model.state.profiles) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(p.label)\(p.id == model.state.activeId ? "  (active)" : "")").bold()
                            Text("\(p.email) · \(p.role.rawValue) · Desktop login \(p.hasDesktopSnapshot ? "saved" : "not saved")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.remove(p) }
                    }
                }
            }
            Section("Save current login as…") {
                Text("Sign in with `claude` → `/login` (and in Claude Desktop) to the account first.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Label", text: $form.label)
                Picker("Role", selection: $form.role) {
                    Text("Main").tag(ProfileRole.main)
                    Text("Backup").tag(ProfileRole.backup)
                }
                Toggle("Also save Claude Desktop's sign-in (Desktop must be signed in to this same account; it will be quit and reopened)", isOn: $form.includeDesktop)
                Button("Save current login") {
                    Task { await model.captureCurrent(label: form.label, role: form.role, includeDesktop: form.includeDesktop) }
                }
                .disabled(form.label.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
            }
            Section("Settings") {
                Toggle("Share all sessions automatically", isOn: Binding(get: { model.state.shareAll }, set: { model.setShareAll($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { model.reload() }
    }
}
