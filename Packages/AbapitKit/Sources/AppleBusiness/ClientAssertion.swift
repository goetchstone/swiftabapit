import Foundation
import JSONAPI
import Vault

/// The ES256 client assertion Apple's OAuth endpoint takes (plan §3.4.2; abapit's `build_client_assertion`,
/// held to `Tests/Fixtures/parity/auth_claims.json` in everything but `exp`).
///
/// - header `{"alg":"ES256","kid":<key ID>,"typ":"JWT"}`;
/// - claims `iss` (the team ID, else the client ID), `sub` (the client ID), `aud` (the **v2** token URL,
///   unlike the URL the request goes to), `iat`, `exp`, `jti` (a UUID);
/// - signed by the Keychain key, the signature raw `r‖s`, base64url without padding.
///
/// `exp` is `iat` + `lifetime`: an hour, not abapit's 179 days. An assertion mints tokens for as long as it
/// lives, and this app signs one per token (Phase 1's live check settles whether Apple takes one twice).
public enum ClientAssertion {
    public static let audience = "https://account.apple.com/auth/oauth2/v2/token"
    public static let lifetime: TimeInterval = 3600
    /// Apple's cap on an assertion's life.
    public static let longestLifetime: TimeInterval = 180 * 86_400

    public struct Claims: Sendable, Equatable {
        public let keyID: String
        public let issuer: String
        public let subject: String
        public let issuedAt: Int
        public let expires: Int
        public let id: String

        public init(clientID: String, keyID: String, teamID: String, now: Date, lifetime: TimeInterval = ClientAssertion.lifetime,
                    id: UUID = UUID()) {
            self.keyID = keyID
            issuer = teamID.isEmpty ? clientID : teamID
            subject = clientID
            issuedAt = Int(now.timeIntervalSince1970)
            expires = issuedAt + Int(min(lifetime, ClientAssertion.longestLifetime - 1))
            self.id = id.uuidString.lowercased()
        }

        /// `header.payload`, base64url: what is signed.
        public var signingInput: String {
            let header: JSONObject = ["alg": .string("ES256"), "kid": .string(keyID), "typ": .string("JWT")]
            let payload: JSONObject = ["iss": .string(issuer), "sub": .string(subject), "aud": .string(ClientAssertion.audience),
                                       "iat": .number(String(issuedAt)), "exp": .number(String(expires)), "jti": .string(id)]
            return Base64URL.encode(Data(JSONValue.dumps(.object(header)).utf8)) + "." + Base64URL.encode(Data(JSONValue.dumps(.object(payload)).utf8))
        }
    }

    /// The signed assertion. The key never leaves the Vault; this may prompt for Touch ID once per session.
    package static func sign(_ claims: Claims, with key: VaultItem, vault: Vault) async throws -> Secret {
        let input = claims.signingInput
        let signature = try await vault.sign(Data(input.utf8), with: key)
        return Secret(input + "." + Base64URL.encode(signature))
    }
}
