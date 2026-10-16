import CryptoKit
import Darwin
import Foundation

/// A P-256 key read from the operator's `.pem`, ready to store. Opaque: only `KeyImport` makes one, and
/// nothing outside the package can read its bytes.
public struct ImportedKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let key: P256.Signing.PrivateKey

    /// The public key's SHA-256, in hex: shown so the operator can tell two keys apart, never the key itself.
    public var fingerprint: String {
        SHA256.hash(data: key.publicKey.x963Representation).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { "<P-256 key \(fingerprint.prefix(12))>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Importing an Apple API key (plan §3.4.1): read the picked file once, by descriptor, then normalize and
/// parse it as abapit's `config.normalize_private_key` does, P-256 only. Held to
/// `Tests/Fixtures/parity/private_keys.json`.
public enum KeyImport {
    /// A PEM key is a few hundred bytes; anything past this isn't one.
    public static let maximumBytes = 16 * 1024

    public enum Failure: Error, Equatable, Sendable {
        case unreadable(errno: Int32)
        case notARegularFile
        case tooLarge
        /// Not a P-256 private key in PEM, under either label.
        case notAKey

        public var message: String {
            switch self {
            case .unreadable(let code): "The file couldn't be read (\(String(cString: strerror(code))))."
            case .notARegularFile: "That isn't a regular file (a link, a folder or a device)."
            case .tooLarge: "That file is too large to be a private key."
            case .notAKey: "That isn't the P-256 private key Apple Business or Apple School Manager generated for an API account."
            }
        }
    }

    /// The file's bytes, read once: opened `O_NOFOLLOW | O_NONBLOCK`, `fstat` must show a regular file
    /// under the size cap, and the bytes come from that same descriptor (SwiftGamGui invariant 5).
    public static func read(_ url: URL) throws(Failure) -> Secret {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw .unreadable(errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unreadable(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile }
        guard info.st_size <= maximumBytes else { throw .tooLarge }
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        var total = 0
        while total < buffer.count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if got < 0 { throw .unreadable(errno: errno) }
            if got == 0 { break }
            total += got
        }
        guard total <= maximumBytes else { throw .tooLarge }
        defer { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        return Secret(Data(buffer[..<total]))
    }

    /// abapit's normalization: CR LF and CR become LF, the text is stripped, and the label is tried as given,
    /// then with `EC PRIVATE KEY` and `PRIVATE KEY` swapped (keys for API accounts sometimes arrive with a
    /// PKCS#8 body under the SEC1 label). Unlike abapit, only P-256 is accepted: any other key would import
    /// and then fail to sign (a listed deviation in the golden).
    public static func parse(_ pem: Secret) throws(Failure) -> ImportedKey {
        let text = String(decoding: pem.bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        var candidates = [text]
        if text.contains("BEGIN EC PRIVATE KEY") {
            candidates.append(text.replacingOccurrences(of: "BEGIN EC PRIVATE KEY", with: "BEGIN PRIVATE KEY")
                .replacingOccurrences(of: "END EC PRIVATE KEY", with: "END PRIVATE KEY"))
        } else if text.contains("BEGIN PRIVATE KEY") {
            candidates.append(text.replacingOccurrences(of: "BEGIN PRIVATE KEY", with: "BEGIN EC PRIVATE KEY")
                .replacingOccurrences(of: "END PRIVATE KEY", with: "END EC PRIVATE KEY"))
        }
        for candidate in candidates {
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: candidate) {
                return ImportedKey(key: key)
            }
        }
        throw .notAKey
    }
}

/// Base64url without padding (RFC 7515 §2), for JWS. `Data.Base64EncodingOptions` has no URL alphabet in
/// this SDK (plan Appendix E), so it is three replacements.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        guard text.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
            || $0 == "-" || $0 == "_" }) else { return nil }
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}
