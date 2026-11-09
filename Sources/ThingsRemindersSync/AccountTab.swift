import SwiftUI
import SyncCore

struct AccountTab: View {
    let coordinator: SyncCoordinator

    var body: some View {
        Form {
            Section("Things Cloud") {
                switch coordinator.thingsAccount {
                case .signedOut:
                    SignInForm(coordinator: coordinator)
                case .signedIn(let email):
                    LabeledContent("Signed in as", value: email)
                    Button("Sign Out", role: .destructive) { coordinator.signOut() }
                }
            }
            Section("Reminders") {
                RemindersAccessRow(coordinator: coordinator)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SignInForm: View {
    let coordinator: SyncCoordinator
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorText: String?

    var body: some View {
        TextField("Email", text: $email)
            .textContentType(.username)
            .autocorrectionDisabled()
        SecureField("Password", text: $password)
            .textContentType(.password)
            .onSubmit(signIn)
        if let errorText {
            Text(errorText).foregroundStyle(.red).font(.callout)
        }
        HStack {
            Button("Sign In", action: signIn)
                .disabled(email.isEmpty || password.isEmpty || isSigningIn)
            if isSigningIn { ProgressView().controlSize(.small) }
        }
    }

    private func signIn() {
        guard !email.isEmpty, !password.isEmpty, !isSigningIn else { return }
        isSigningIn = true
        errorText = nil
        Task {
            do {
                try await coordinator.signIn(email: email, password: password)
                password = ""
            } catch {
                errorText = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}

private struct RemindersAccessRow: View {
    let coordinator: SyncCoordinator

    var body: some View {
        switch coordinator.remindersAccess {
        case .granted:
            Label("Access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notDetermined:
            Label("Not requested yet", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            Button("Request Access") { Task { await coordinator.requestRemindersAccess() } }
        case .denied:
            Label("Access denied", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text("Allow Things Reminders Sync in System Settings > Privacy & Security > Reminders.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

#Preview {
    AccountTab(coordinator: SyncCoordinator())
        .frame(width: 560, height: 420)
}
