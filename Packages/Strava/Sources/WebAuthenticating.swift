import Foundation
import AuthenticationServices
import UIKit

/// Presents the OAuth consent page and returns the redirect callback URL.
/// Abstracted so the auth manager can be driven by a stub in tests.
public protocol WebAuthenticating: Sendable {
    /// Opens `url` in a secure web context and resolves with the callback URL
    /// once the browser redirects to `callbackScheme://…`.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// `ASWebAuthenticationSession`-backed implementation used in the app.
@MainActor
public final class ASWebAuthenticationProvider: NSObject, WebAuthenticating {
    private let prefersEphemeral: Bool

    public init(prefersEphemeral: Bool = false) {
        self.prefersEphemeral = prefersEphemeral
        super.init()
    }

    public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? StravaError.notAuthenticated)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = prefersEphemeral
            session.start()
        }
    }
}

extension ASWebAuthenticationProvider: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The key window of the active foreground scene.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
