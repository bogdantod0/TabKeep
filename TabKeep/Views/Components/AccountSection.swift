import SwiftUI
import AuthenticationServices

struct AccountSection: View {
    @Environment(AuthSession.self) private var authSession
    @Environment(\.colorScheme) private var colorScheme

    @State private var inlineErrorMessage: String?
    @State private var alertError: APIError?
    @State private var showingSignOutConfirm = false
    @State private var showingDeleteAccountConfirm = false
    @State private var isWorking = false

    var body: some View {
        Group {
            switch authSession.state {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Loading account…").foregroundStyle(.secondary)
                }
            case .anonymous:
                anonymousView
            case .signedIn(_, let providers, _) where providers.isEmpty:
                // Device is server-registered (so it can mint/accept invites
                // and sync), but no Apple/Google provider has been linked.
                // Surface the same "Back up your account" CTA as `.anonymous`
                // so the user isn't misled into thinking they're signed in.
                anonymousView
            case .signedIn(let user, let providers, _):
                signedInView(user: user, providers: providers)
            }
        }
        .alert(
            "Sign in failed",
            isPresented: Binding(get: { alertError != nil }, set: { if !$0 { alertError = nil } })
        ) {
            Button("OK") { alertError = nil }
        } message: {
            Text(alertError?.userMessage ?? "")
        }
        .confirmationDialog(
            "Sign out?",
            isPresented: $showingSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { Task { await performSignOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your local groups stay on this device.")
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingDeleteAccountConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) { Task { await performDeleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your account and disconnects you from shared groups. Other members keep their copy of past expenses. This can't be undone.")
        }
    }

    // MARK: - Anonymous

    private var anonymousView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // SignInWithAppleButton is the HIG-compliant button. It manages its
            // own tap; on completion we feed the credential into AuthSession.
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email, .fullName]
            } onCompletion: { result in
                Task { await performAppleSignIn(from: result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)
            .disabled(isWorking)

            googleButton
                .disabled(isWorking)

            if let inlineErrorMessage {
                Text(inlineErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    /// Google brand spec dark-variant surface (#131314).
    private static let googleDarkBackground = Color(
        red: 0x13 / 255.0,
        green: 0x13 / 255.0,
        blue: 0x14 / 255.0
    )
    private static let googleButtonCornerRadius: CGFloat = 8

    private var googleButton: some View {
        Button {
            Task { await performSignIn(.google) }
        } label: {
            HStack(spacing: 10) {
                Image("google-g")
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text("Sign in with Google")
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(.primary)
            .background(googleButtonBackground)
            .overlay(googleButtonBorder)
            .clipShape(RoundedRectangle(cornerRadius: Self.googleButtonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var googleButtonBackground: some View {
        RoundedRectangle(cornerRadius: Self.googleButtonCornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Self.googleDarkBackground : Color.white)
    }

    @ViewBuilder
    private var googleButtonBorder: some View {
        if colorScheme != .dark {
            RoundedRectangle(cornerRadius: Self.googleButtonCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
        }
    }

    // MARK: - Signed in

    private func signedInView(user: UserDTO, providers: [String]) -> some View {
        VStack(spacing: 8) {
            destructiveActionButton(
                icon: "rectangle.portrait.and.arrow.right",
                title: "Sign out",
                accessibilityIdentifier: "signOutButton"
            ) {
                showingSignOutConfirm = true
            }

            destructiveActionButton(
                icon: "trash.fill",
                title: "Delete account",
                accessibilityIdentifier: "deleteAccountButton"
            ) {
                showingDeleteAccountConfirm = true
            }

            if let inlineErrorMessage {
                Text(inlineErrorMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func destructiveActionButton(
        icon: String,
        title: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(AppTheme.danger)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.danger.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppTheme.danger.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    // MARK: - Actions

    @MainActor
    private func performSignIn(_ provider: AuthProvider) async {
        // Used for Google only; Apple sign-in goes through performAppleSignIn(from:)
        // because we use the HIG-compliant SignInWithAppleButton instead of
        // routing through AppleSignInCoordinator on the anonymous path.
        await runAuthFlow {
            try await authSession.signIn(with: provider, idTokenProvider: { @MainActor in
                try await fetchIDToken(for: provider)
            })
        }
    }

    @MainActor
    private func performAppleSignIn(from result: Result<ASAuthorization, Error>) async {
        inlineErrorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let auth = try result.get()
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let data = cred.identityToken,
                  let token = String(data: data, encoding: .utf8) else {
                alertError = .unexpected(status: 0, bodyPreview: "no_identity_token")
                return
            }
            try await authSession.signIn(with: .apple, idTokenProvider: { token })
        } catch let err as APIError {
            if err.preferAlert { alertError = err } else { inlineErrorMessage = err.userMessage }
        } catch {
            if let asErr = error as? ASAuthorizationError, asErr.code == .canceled {
                // user dismissed; silent
            } else {
                alertError = .unexpected(status: 0, bodyPreview: String(describing: error))
            }
        }
    }

    @MainActor
    private func performDeleteAccount() async {
        inlineErrorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await authSession.deleteAccount()
        } catch let err as APIError {
            // 422 validation_failed with reason "account_has_owned_groups"
            // is the most likely refusal — surface a tailored message.
            if case .server(let code, let message, _, _) = err,
               code == "validation_failed",
               message.contains("account_has_owned_groups") || message.lowercased().contains("group") {
                inlineErrorMessage = "You still own group(s) with other members. Delete or leave those groups first, then try again."
            } else if err.preferAlert {
                alertError = err
            } else {
                inlineErrorMessage = err.userMessage
            }
        } catch {
            alertError = .unexpected(status: 0, bodyPreview: String(describing: error))
        }
    }

    @MainActor
    private func performSignOut() async {
        inlineErrorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await authSession.signOut()
        } catch let err as APIError {
            if err.preferAlert {
                alertError = err
            } else {
                inlineErrorMessage = err.userMessage
            }
        } catch {
            alertError = .unexpected(status: 0, bodyPreview: String(describing: error))
        }
    }

    private func runAuthFlow(_ work: @escaping () async throws -> Void) async {
        inlineErrorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
        } catch AuthError.cancelled {
            // silent
        } catch let err as APIError {
            if err.preferAlert {
                alertError = err
            } else {
                inlineErrorMessage = err.userMessage
            }
        } catch let err as AuthError {
            if case .failed(let reason) = err {
                alertError = .unexpected(status: 0, bodyPreview: reason)
            }
        } catch {
            alertError = .unexpected(status: 0, bodyPreview: String(describing: error))
        }
    }

    @MainActor
    private func fetchIDToken(for provider: AuthProvider) async throws -> String {
        switch provider {
        case .apple:
            guard let anchor = topPresentationAnchor() else {
                throw AuthError.failed(reason: "no_window")
            }
            return try await AppleSignInCoordinator.idToken(presenting: anchor)
        case .google:
            guard let vc = topViewController() else {
                throw AuthError.failed(reason: "no_view_controller")
            }
            return try await GoogleSignInCoordinator.idToken(presenting: vc)
        }
    }

    @MainActor
    private func topPresentationAnchor() -> ASPresentationAnchor? {
        topWindow()
    }

    @MainActor
    private func topWindow() -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    }

    @MainActor
    private func topViewController() -> UIViewController? {
        guard var vc = topWindow()?.rootViewController else { return nil }
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }
}
