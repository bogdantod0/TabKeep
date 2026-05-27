import Foundation
import GoogleSignIn
import UIKit

@MainActor
enum GoogleSignInCoordinator {
    /// Returns the Google OIDC ID token on success.
    /// `presenting` must be the topmost view controller.
    static func idToken(presenting rootViewController: UIViewController) async throws -> String {
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            guard let token = result.user.idToken?.tokenString else {
                throw AuthError.failed(reason: "google_no_id_token")
            }
            return token
        } catch let err as NSError {
            // GIDSignInError.canceled = -5 historically; check by code.
            if err.domain == "com.google.GIDSignIn" && err.code == -5 {
                throw AuthError.cancelled
            }
            if err.domain == GIDSignInError.errorDomain {
                if err.code == GIDSignInError.canceled.rawValue {
                    throw AuthError.cancelled
                }
            }
            throw AuthError.failed(reason: "google_\(err.code)")
        }
    }
}
