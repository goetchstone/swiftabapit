import AppleBusiness
import CryptoKit
import Foundation
import JSONAPI
import Testing
import TestSupport
import Vault

/// abapit's `build_client_assertion`, held to `Tests/Fixtures/parity/auth_claims.json` in its header and
/// claims. One listed deviation: `exp` is an hour after `iat`, not 179 days (an assertion mints tokens for as
/// long as it lives).
@Suite("Client assertion parity")
struct ClientAssertionTests {
    struct Golden: Decodable {
        struct Case: Decodable {
            struct Input: Decodable {
                let client_id: String, key_id: String, team_id: String, scope: String, now: Int
            }
            struct Expected: Decodable {
                let header: [String: String]
                let payload: [String: PayloadValue]
                let token_scope: String
                let token_url: String
                let signature_bytes: Int
            }
            let input: Input
            let expected: Expected
        }
        let cases: [Case]
    }

    enum PayloadValue: Decodable, Equatable {
        case string(String), int(Int)
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) { self = .int(int) } else { self = .string(try container.decode(String.self)) }
        }
    }

    static func decode(_ part: Substring) throws -> [String: JSONValue] {
        let data = try #require(Base64URL.decode(String(part)))
        let object = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self))?.object)
        return Dictionary(uniqueKeysWithValues: object.members.map { ($0.key, $0.value) })
    }

    @Test func headerAndClaimsMatchAbapitButExp() async throws {
        let golden = try JSONDecoder().decode(Golden.self, from: Fixtures.parity("auth_claims"))
        #expect(golden.cases.count == 2)
        for item in golden.cases {
            let claims = ClientAssertion.Claims(clientID: item.input.client_id, keyID: item.input.key_id, teamID: item.input.team_id,
                                                now: Date(timeIntervalSince1970: TimeInterval(item.input.now)))
            let parts = claims.signingInput.split(separator: ".")
            #expect(parts.count == 2)
            let header = try Self.decode(parts[0]), payload = try Self.decode(parts[1])
            #expect(header.mapValues(\.string) == item.expected.header.mapValues { Optional($0) })
            for key in ["iss", "sub", "aud"] {
                #expect(payload[key]?.string.map(PayloadValue.string) == item.expected.payload[key], "\(key)")
            }
            #expect(payload["iat"]?.int.map(PayloadValue.int) == item.expected.payload["iat"])
            // The deviation: an hour, not abapit's 179 days.
            #expect(payload["exp"]?.int == item.input.now + 3600)
            #expect(item.expected.payload["exp"] == .int(item.input.now + 179 * 86_400))
            #expect(UUID(uuidString: payload["jti"]?.string ?? "") != nil)
            #expect(item.expected.token_url == "https://account.apple.com/auth/oauth2/token")
            #expect(item.expected.signature_bytes == 64)
        }
    }

    @Test func theSignatureIsRawAndVerifies() async throws {
        let key = P256.Signing.PrivateKey(), store = MemoryStore(), vault = Vault(store: store)
        let item = try #require(VaultItem(org: "acme", kind: .appleKey))
        try await vault.storeKey(KeyImport.importForTests(key), as: item)
        let claims = ClientAssertion.Claims(clientID: "BUSINESSAPI.1", keyID: "K", teamID: "", now: Date())
        let assertion = try await ClientAssertion.sign(claims, with: item, vault: vault)
        let text = String(decoding: assertion.bytes, as: UTF8.self)
        let parts = text.split(separator: ".")
        #expect(parts.count == 3)
        let signature = try #require(Base64URL.decode(String(parts[2])))
        #expect(signature.count == 64)
        #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature),
                                               for: Data("\(parts[0]).\(parts[1])".utf8)))
    }
}
