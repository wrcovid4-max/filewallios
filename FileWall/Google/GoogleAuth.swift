import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Native Google OAuth for an iOS "installed app" client — **no GoogleSignIn SDK,
/// no AppAuth**. `ASWebAuthenticationSession` + PKCE is Apple's dependency-free,
/// Google-supported path, and mirrors the Android app's raw approach.
///
/// # Token handling
/// - `refresh_token` → Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
///   (survives locks so a background sync can refresh; never syncs to iCloud).
/// - `access_token` → memory only, with its expiry. Refreshed on demand.
/// - **No client secret.** iOS clients are public; PKCE is the proof-of-possession.
@MainActor
final class GoogleAuth: NSObject, ObservableObject {

    static let shared = GoogleAuth()

    struct Tokens {
        var accessToken: String
        var expiry: Date
        var refreshToken: String?
        var email: String?
    }

    @Published private(set) var email: String?
    @Published private(set) var isSignedIn: Bool = false

    private var tokens: Tokens?
    private let keychain = RefreshTokenStore()
    // Held for the lifetime of the auth flow: a local ASWebAuthenticationSession
    // would be deallocated when `presentAuthSession` returns, before its callback
    // fires. Retaining it here keeps the browser sheet alive.
    private var currentSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        // A stored refresh token means "signed in" across launches, even before
        // the first Drive call mints an access token.
        if keychain.load() != nil { isSignedIn = true }
    }

    enum AuthError: Error, Equatable {
        case notConfigured
        case cancelled
        case badResponse
        case notSignedIn
    }

    // MARK: - Sign in

    func signIn() async throws {
        guard GoogleConfig.isConfigured else { throw AuthError.notConfigured }

        let verifier = Self.pkceVerifier()
        let challenge = Self.pkceChallenge(for: verifier)

        var comps = URLComponents(url: GoogleConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: GoogleConfig.clientID),
            .init(name: "redirect_uri", value: GoogleConfig.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleConfig.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // offline + consent so we reliably receive a refresh_token.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]

        let callbackURL = try await presentAuthSession(url: comps.url!)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.badResponse
        }
        try await exchangeCode(code, verifier: verifier)
    }

    private func presentAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: GoogleConfig.callbackScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.badResponse)
                }
            }
            session.presentationContextProvider = self
            // false: reuse the user's existing Google session in Safari, so a
            // signed-in user isn't forced to re-type their password.
            session.prefersEphemeralWebBrowserSession = false
            self.currentSession = session
            session.start()
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeCode(_ code: String, verifier: String) async throws {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": GoogleConfig.clientID,
            "redirect_uri": GoogleConfig.redirectURI
        ]
        let json = try await postForm(form)
        guard let access = json["access_token"] as? String,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            throw AuthError.badResponse
        }
        let refresh = json["refresh_token"] as? String
        let mail = (json["id_token"] as? String).flatMap(Self.email(fromIDToken:))

        if let refresh { keychain.save(refresh) }
        tokens = Tokens(accessToken: access,
                        expiry: Date().addingTimeInterval(expiresIn - 60), // refresh a minute early
                        refreshToken: refresh ?? keychain.load(),
                        email: mail)
        email = mail
        isSignedIn = true
    }

    /// A valid access token, refreshing via the stored refresh token if needed.
    /// This is what every Drive call asks for first.
    func validAccessToken() async throws -> String {
        if let t = tokens, t.expiry > Date() { return t.accessToken }
        guard let refresh = tokens?.refreshToken ?? keychain.load() else { throw AuthError.notSignedIn }

        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": GoogleConfig.clientID
            // NO client_secret — public client.
        ]
        let json = try await postForm(form)
        guard let access = json["access_token"] as? String,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            throw AuthError.badResponse
        }
        let mail = (json["id_token"] as? String).flatMap(Self.email(fromIDToken:)) ?? tokens?.email
        tokens = Tokens(accessToken: access,
                        expiry: Date().addingTimeInterval(expiresIn - 60),
                        refreshToken: refresh,
                        email: mail)
        if let mail { email = mail }
        isSignedIn = true
        return access
    }

    func signOut() {
        tokens = nil
        keychain.delete()
        email = nil
        isSignedIn = false
    }

    private func postForm(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: GoogleConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.badResponse
        }
        return json
    }

    // MARK: - PKCE + helpers

    /// 43-char base64url verifier (32 random bytes) — within the 43…128 spec range.
    private static func pkceVerifier() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    private static func pkceChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Pull "email" from the id_token JWT payload (middle base64url segment). No
    /// signature verification here — the token came straight from Google's TLS
    /// endpoint and is used only for display, never for authorization.
    static func email(fromIDToken idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }
}

extension GoogleAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The key window of the active scene. Sign-in only happens with the app
        // foregrounded (the "Sign in to Google" path opens the app), so a window
        // exists.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}

/// Keychain storage for the refresh token. `AfterFirstUnlockThisDeviceOnly` so a
/// background sync after the first unlock can still refresh, while the token never
/// leaves the device and never enters an iCloud/device backup.
private struct RefreshTokenStore {
    private let service = "com.filewall.google.refresh"
    private let account = "primary"

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func save(_ token: String) {
        delete()
        var attrs = base
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
