import Foundation
import AuthenticationServices
import UIKit

@MainActor
final class AppleSignInCoordinator: NSObject {
    private var continuation: CheckedContinuation<String, Error>?
    private let presentationAnchor: ASPresentationAnchor

    private init(anchor: ASPresentationAnchor) {
        self.presentationAnchor = anchor
        super.init()
    }

    /// Returns the Apple OIDC ID token (raw JWT) on success.
    static func idToken(presenting anchor: ASPresentationAnchor) async throws -> String {
        let coordinator = AppleSignInCoordinator(anchor: anchor)
        return try await coordinator.start()
    }

    private func start() async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            controller.performRequests()
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                self.continuation?.resume(throwing: AuthError.failed(reason: "no_identity_token"))
                self.continuation = nil
                return
            }
            self.continuation?.resume(returning: token)
            self.continuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: Error) {
        Task { @MainActor in
            if let asError = error as? ASAuthorizationError {
                if asError.code == .canceled {
                    self.continuation?.resume(throwing: AuthError.cancelled)
                } else {
                    self.continuation?.resume(throwing: AuthError.failed(reason: "apple_\(asError.code.rawValue)"))
                }
            } else {
                self.continuation?.resume(throwing: AuthError.failed(reason: "apple_\(error.localizedDescription)"))
            }
            self.continuation = nil
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // ASPresentationAnchor is `UIWindow` on iOS; safe to read from any context.
        MainActor.assumeIsolated { presentationAnchor }
    }
}
