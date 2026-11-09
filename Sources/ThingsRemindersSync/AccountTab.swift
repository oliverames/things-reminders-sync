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
            Section("Reminders (RemCTL)") {
                RemCTLRow(coordinator: coordinator)
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

private struct RemCTLRow: View {
    let coordinator: SyncCoordinator
    @State private var path = ""
    @State private var isChecking = false

    var body: some View {
        Group {
            if coordinator.remindersAccess == .granted {
                Label(coordinator.remindersDetail, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(coordinator.remindersDetail, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Reminders is read through RemCTL. Install it and authorize its Capability Host (run remctl doctor).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("RemCTL path (optional)", text: $path, prompt: Text("~/bin/remctl"))
                .autocorrectionDisabled()
                .onSubmit(applyPath)
            HStack {
                Button("Check Again") {
                    isChecking = true
                    Task {
                        applyPath()
                        await coordinator.requestRemindersAccess()
                        isChecking = false
                    }
                }
                .disabled(isChecking)
                if isChecking { ProgressView().controlSize(.small) }
            }
        }
        .onAppear { path = coordinator.config.remctlPath ?? "" }
    }

    /// Saves the path through `updateConfig`; clearing the field returns to the default locations.
    private func applyPath() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != coordinator.config.remctlPath else { return }
        var config = coordinator.config
        config.remctlPath = value
        Task { await coordinator.updateConfig(config) }
    }
}

#Preview {
    AccountTab(coordinator: SyncCoordinator())
        .frame(width: 560, height: 420)
}
