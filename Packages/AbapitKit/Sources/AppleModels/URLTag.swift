/// HMAC-SHA256 (FIPS 180-4, RFC 2104), for `WebhookURL.tag` only. Written out here because this module is pure: it
/// builds on Linux for the fuzz job and imports only Foundation, so CryptoKit isn't available (`PackageGraphTests`).
/// Held to RFC 4231's and FIPS 180-4's vectors, and to CryptoKit where a test can import it (`WebhookTests`). Not for
/// anything a secret depends on: a tag only says whether two URLs this run masked were the same.
enum TagHash {
    /// The first 32 bits of the fractional parts of the cube roots of the first 64 primes.
    private static let rounds: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// The first 32 bits of the fractional parts of the square roots of the first 8 primes.
    private static let initial: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

    static func sha256(_ message: [UInt8]) -> [UInt8] {
        var state = initial
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        var words = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: padded.count, by: 64) {
            for index in 0..<16 {
                let at = block + index * 4
                words[index] = UInt32(padded[at]) << 24 | UInt32(padded[at + 1]) << 16 | UInt32(padded[at + 2]) << 8 | UInt32(padded[at + 3])
            }
            for index in 16..<64 {
                let early = words[index - 15], late = words[index - 2]
                let s0 = rotate(early, 7) ^ rotate(early, 18) ^ (early >> 3)
                let s1 = rotate(late, 17) ^ rotate(late, 19) ^ (late >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
            for index in 0..<64 {
                let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let first = h &+ sum1 &+ choice &+ rounds[index] &+ words[index]
                let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let second = sum0 &+ majority
                (h, g, f, e, d, c, b, a) = (g, f, e, d &+ first, c, b, a, first &+ second)
            }
            for (index, value) in [a, b, c, d, e, f, g, h].enumerated() { state[index] = state[index] &+ value }
        }
        return state.flatMap { word in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) } }
    }

    /// HMAC-SHA256 of `message` under `key`.
    static func hmac(key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        var block = key.count > 64 ? sha256(key) : key
        block += [UInt8](repeating: 0, count: 64 - block.count)
        let inner = sha256(block.map { $0 ^ 0x36 } + message)
        return sha256(block.map { $0 ^ 0x5c } + inner)
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }
}
