import Foundation

/// A custom setting's `configurationProfile` as the configuration detail shows it (plan Phase 2): the property list
/// pretty-printed, with every secret masked (invariant 11); a signed profile never shown; anything else a short note,
/// never the value. A profile can hold Wi-Fi and VPN passwords, shared secrets and a certificate's private key.
///
/// It reads what Apple may send: XML text (Apple's examples) or base64 (Apple types the field `byte`) of an XML or a
/// binary property list. The text is bounded before anything reads it, and the property-list readers in Foundation,
/// which recurse once per level of nesting, see only input whose nesting is bounded: an XML profile is scanned first,
/// refusing any DTD or entity declaration but Apple's plist DOCTYPE, any encoding but UTF-8 and nesting past
/// `maximumDepth`; a binary one has its object table checked and its containers counted. Pure Foundation, so it builds
/// on Linux for the fuzz job.
public enum ProfileText: Sendable, Equatable {
    /// The profile as XML, with `masked` values replaced by `mask`, and `merged` keys that read as another: written twice
    /// alike (Foundation's reader keeps one), or equal once normalized (Swift's dictionaries compare canonically). One
    /// value of each such pair isn't in the text, and `note` says so.
    case plist(String, masked: Int, merged: Int)
    /// A signed profile (CMS SignedData): its content holds the profile, secrets and all, in the clear.
    case signed(bytes: Int)
    /// Not shown, and why.
    case notShown(String)

    /// The most UTF-8 bytes read, before anything else is done.
    public static let maximumBytes = 1 << 20
    /// The deepest nesting of dictionaries and arrays read. Profiles nest a handful of levels.
    public static let maximumDepth = 64
    /// The most dictionaries, arrays and sets a binary plist may hold: Foundation's reader recurses through them, so
    /// their count bounds its depth before it runs.
    public static let maximumContainers = 256
    /// The most values the masking walk visits: a binary plist can reference one object many times, so 25 levels of
    /// `[a, a]` are 2^25 values to a walk.
    public static let maximumValues = 200_000
    public static let mask = "********"

    public static let unreadable = "not a property list, not shown"
    public static let declaration = "declares a DTD or an entity, not shown"
    public static let notUTF8 = "not UTF-8, not shown"
    public static let tooDeep = "nested too deeply to show"
    public static let tooMany = "too many values to show"
    public static func tooLarge(bytes: Int) -> String { "too large to show: \(bytes) bytes (the most shown is \(maximumBytes))" }

    /// What the detail view shows.
    public var text: String {
        switch self {
        case .plist(let text, _, _): text
        case .signed(let bytes): "signed profile, \(bytes) bytes, not shown"
        case .notShown(let reason): reason
        }
    }

    /// What the detail view says under a shown profile: how many values were masked, and how many keys aren't shown
    /// because each repeats another, as written or once normalized, rather than gone unsaid (Phase 2a review L2; verifier
    /// round 2: a key written twice alike was dropped unsaid, as Foundation's reader keeps one).
    public var note: String? {
        guard case .plist(_, let masked, let merged) = self else { return nil }
        let parts = [masked == 0 ? nil : "\(masked) value\(masked == 1 ? "" : "s") masked",
                     merged == 0 ? nil : "\(merged) key\(merged == 1 ? "" : "s") not shown: each repeats another key, as written or once normalized"]
        let said = parts.compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: " · ")
    }

    public init(_ profile: String) {
        let size = profile.utf8.count
        guard size <= Self.maximumBytes else {
            self = .notShown(Self.tooLarge(bytes: size))
            return
        }
        guard let bytes = Self.bytes(of: Array(profile.utf8)) else {
            self = .notShown(Self.unreadable)
            return
        }
        self = Self.show(bytes)
    }

    // MARK: Reading the bytes

    /// XML text as it is; anything else must be base64 (whitespace allowed, padding optional).
    private static func bytes(of text: [UInt8]) -> [UInt8]? {
        if xmlStart(text) != nil { return text }
        let stripped = text.filter { !isSpace($0) }
        guard !stripped.isEmpty, stripped.allSatisfy(isBase64) else { return nil }
        let padded = stripped + Array(repeating: UInt8(ascii: "="), count: (4 - stripped.count % 4) % 4)
        return Data(base64Encoded: Data(padded)).map(Array.init)
    }

    private static func show(_ bytes: [UInt8]) -> ProfileText {
        if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE]) { return .notShown(notUTF8) }
        if bytes.starts(with: Array("bplist00".utf8)) {
            guard let containers = binaryContainers(bytes) else { return .notShown(unreadable) }
            guard containers <= maximumContainers else { return .notShown(tooMany) }
            return parse(bytes, as: .binary)
        }
        if let start = xmlStart(bytes) {
            let scan = xmlScan(bytes, from: start)
            if let refusal = scan.refusal { return .notShown(refusal) }
            return parse(Array(bytes[start...]), as: .xml, keys: scan.keys)
        }
        return isSignedData(bytes) ? .signed(bytes: bytes.count) : .notShown(unreadable)
    }

    /// `keys`, for XML: how many keys the text holds, so the ones Foundation's reader kept once for two are counted. A
    /// binary plist's aren't counted: one of its dictionaries can be referenced twice, so its table isn't the tree.
    private static func parse(_ bytes: [UInt8], as expected: PropertyListSerialization.PropertyListFormat, keys: Int? = nil) -> ProfileText {
        var format = expected
        // Read only as the format the bytes were checked as: Foundation also reads OpenStep text, which the checks don't.
        guard let tree = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: &format),
              format == expected else { return .notShown(unreadable) }
        var walk = MaskingWalk()
        guard let masked = walk.mask(tree, depth: 0) else { return .notShown(walk.refusal) }
        guard let out = try? PropertyListSerialization.data(fromPropertyList: masked, format: .xml, options: 0) else {
            return .notShown(unreadable)
        }
        let repeated = keys.map { max(0, $0 - keyCount(tree)) } ?? 0
        return .plist(String(decoding: out, as: UTF8.self), masked: walk.masked, merged: walk.merged + repeated)
    }

    /// The keys of every dictionary in a tree the scan bounded (an XML one: no object in it is shared), masked ones too.
    private static func keyCount(_ value: Any) -> Int {
        if let dictionary = value as? NSDictionary { return dictionary.count + dictionary.allValues.reduce(0) { $0 + keyCount($1) } }
        if let dictionary = value as? [String: Any] { return dictionary.count + dictionary.values.reduce(0) { $0 + keyCount($1) } }
        if let array = value as? [Any] { return array.reduce(0) { $0 + keyCount($1) } }
        return 0
    }

    // MARK: XML, scanned before the parser sees it

    /// Where the XML begins: after a UTF-8 byte-order mark and blanks, at a `<`.
    private static func xmlStart(_ bytes: [UInt8]) -> Int? {
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
        return index < bytes.count && bytes[index] == UInt8(ascii: "<") ? index : nil
    }

    /// Apple's plist DOCTYPE, in either of its public identifiers, blanks collapsed: the only declaration read.
    private static let doctypes: [[UInt8]] = ["-//Apple//DTD PLIST 1.0//EN", "-//Apple Computer//DTD PLIST 1.0//EN"].map {
        Array("<!DOCTYPE plist PUBLIC \"\($0)\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">".utf8)
    }

    /// Why the XML isn't handed to the parser, or nil. It skips comments, CDATA and processing instructions as the
    /// reader does, so a declaration or a level of nesting can't hide from it inside what the reader takes as text; a
    /// tag ends at its first `>` (the reader takes no attributes on a dictionary or an array). Foundation's reader also
    /// refuses a DTD's internal subset (checked on macOS 27): this refuses it first, whatever reader runs.
    static func xmlRefusal(_ bytes: [UInt8], from start: Int) -> String? { xmlScan(bytes, from: start).refusal }

    /// `xmlRefusal`'s answer, and how many keys the XML holds: a `<key>` where a dictionary's key goes, every other
    /// element in it, since Foundation's reader takes a `<key>` anywhere else as a string (checked on macOS 27).
    static func xmlScan(_ bytes: [UInt8], from start: Int) -> (refusal: String?, keys: Int) {
        if bytes.contains(0) { return (notUTF8, 0) }
        if bytes[start...].starts(with: Array("<?xml".utf8)) {
            guard let end = find(Array("?>".utf8), in: bytes, from: start) else { return (unreadable, 0) }
            if let encoding = attribute("encoding", in: Array(bytes[start..<end])),
               !encoding.map(lower).elementsEqual("utf-8".utf8) { return (notUTF8, 0) }
        }
        var index = start, depth = 0, doctypes = 0, keys = 0
        // Each element still open: whether it is a dictionary, and how many elements it holds so far. A dictionary's
        // keys are its even ones, as its values are its odd ones.
        var elements: [(dictionary: Bool, children: Int)] = []
        while let open = bytes[index...].firstIndex(of: UInt8(ascii: "<")) {
            let rest = bytes[open...]
            if rest.starts(with: Array("<!--".utf8)) {
                guard let end = find(Array("-->".utf8), in: bytes, from: open + 4) else { return (unreadable, keys) }
                index = end + 3
            } else if rest.starts(with: Array("<![CDATA[".utf8)) {
                guard let end = find(Array("]]>".utf8), in: bytes, from: open + 9) else { return (unreadable, keys) }
                index = end + 3
            } else if rest.starts(with: Array("<?".utf8)) {
                guard let end = find(Array("?>".utf8), in: bytes, from: open + 2) else { return (unreadable, keys) }
                index = end + 2
            } else if rest.starts(with: Array("<!".utf8)) {
                guard let close = bytes[open...].firstIndex(of: UInt8(ascii: ">")) else { return (unreadable, keys) }
                doctypes += 1
                guard doctypes == 1, Self.doctypes.contains(collapsed(bytes[open...close])) else { return (declaration, keys) }
                index = close + 1
            } else {
                guard let close = bytes[open...].firstIndex(of: UInt8(ascii: ">")) else { return (unreadable, keys) }
                let closing = bytes[open + 1] == UInt8(ascii: "/")
                let nameStart = closing ? open + 2 : open + 1
                let name = bytes[nameStart..<close].prefix { !isSpace($0) && $0 != UInt8(ascii: "/") }
                let empty = bytes[close - 1] == UInt8(ascii: "/")
                if name.elementsEqual("dict".utf8) || name.elementsEqual("array".utf8) {
                    if closing {
                        depth -= 1
                        if depth < 0 { return (unreadable, keys) }
                    } else if !empty {
                        depth += 1
                        if depth > maximumDepth { return (tooDeep, keys) }
                    }
                }
                if closing {
                    _ = elements.popLast()
                } else {
                    if let parent = elements.last, parent.dictionary {
                        if parent.children.isMultiple(of: 2), name.elementsEqual("key".utf8) { keys += 1 }
                        elements[elements.count - 1].children += 1
                    }
                    if !empty { elements.append((name.elementsEqual("dict".utf8), 0)) }
                }
                index = close + 1
            }
        }
        return (nil, keys)
    }

    /// The value of `name="…"` or `name='…'` in an XML declaration.
    private static func attribute(_ name: String, in declaration: [UInt8]) -> ArraySlice<UInt8>? {
        guard var index = find(Array(name.utf8), in: declaration, from: 0).map({ $0 + name.utf8.count }) else { return nil }
        while index < declaration.count, isSpace(declaration[index]) || declaration[index] == UInt8(ascii: "=") { index += 1 }
        guard index < declaration.count, [UInt8(ascii: "\""), UInt8(ascii: "'")].contains(declaration[index]) else { return [] }
        let quote = declaration[index]
        guard let end = declaration[(index + 1)...].firstIndex(of: quote) else { return [] }
        return declaration[(index + 1)..<end]
    }

    /// A declaration with each run of blanks one space, for comparing with Apple's.
    private static func collapsed(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        for byte in bytes {
            if isSpace(byte) {
                if out.last != UInt8(ascii: " ") { out.append(UInt8(ascii: " ")) }
            } else {
                out.append(byte)
            }
        }
        return out
    }

    // MARK: Binary, checked before the parser sees it

    /// How many dictionaries, arrays and sets the binary plist holds, or nil when its trailer or offset table points
    /// outside its bytes (Foundation would refuse it too; this never reads past them).
    static func binaryContainers(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 8 + 1 + 32 else { return nil }
        let trailer = bytes.count - 32
        func number(_ at: Int, _ size: Int) -> Int? {
            guard size > 0, at >= 0, at + size <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[at..<(at + size)] {
                guard value <= Int.max >> 8 else { return nil }
                value = value << 8 | Int(byte)
            }
            return value
        }
        let offsetSize = Int(bytes[trailer + 6]), referenceSize = Int(bytes[trailer + 7])
        guard (1...8).contains(offsetSize), (1...8).contains(referenceSize), let count = number(trailer + 8, 8),
              let table = number(trailer + 24, 8), count >= 1, count <= trailer, table >= 8, table < trailer,
              count <= (trailer - table) / offsetSize else { return nil }
        var containers = 0
        for object in 0..<count {
            guard let offset = number(table + object * offsetSize, offsetSize), offset >= 8, offset < table else { return nil }
            if [0xA, 0xB, 0xC, 0xD].contains(bytes[offset] >> 4) { containers += 1 }
        }
        return containers
    }

    // MARK: Signed

    /// DER whose first element is CMS SignedData's OID, 1.2.840.113549.1.7.2.
    private static func isSignedData(_ bytes: [UInt8]) -> Bool {
        let oid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        return bytes.first == 0x30 && find(oid, in: Array(bytes.prefix(32)), from: 0) != nil
    }

    // MARK: Bytes

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard start <= bytes.count else { return nil }
        return bytes[start...].firstRange(of: needle)?.lowerBound
    }

    fileprivate static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    fileprivate static func isBase64(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="): true
        default: false
        }
    }

    fileprivate static func lower(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }
}

/// The walk that masks: every value under a secret key, whole, unless it is a flag, a date, or a number whose key doesn't
/// end in a secret word or names a policy (`PasswordRequired`, `maxPINAgeInDays`, `PasscodeMinLength` are policies; a
/// numeric `Passcode`, `UnlockCode` or `SharedSecret` isn't); every string holding a private key, wherever it is; and every data
/// blob, wherever it is (a certificate, a PKCS#12 identity, a shared secret: none readable, some secret, and an Exchange
/// payload carries an identity outside any certificate payload). Bounded in depth and in the values it visits.
private struct MaskingWalk {
    var masked = 0, merged = 0, visited = 0
    var refusal = ProfileText.unreadable

    mutating func mask(_ value: Any, depth: Int) -> Any? {
        visited += 1
        guard visited <= ProfileText.maximumValues else { refusal = ProfileText.tooMany; return nil }
        if let dictionary = value as? [String: Any] {
            guard depth < ProfileText.maximumDepth else { refusal = ProfileText.tooDeep; return nil }
            // Bridged to a Swift dictionary, keys that differ only in Unicode normalization merge and one value of each
            // pair is gone: counted, so `ProfileText.note` says it (Phase 2a review L2: it was dropped unsaid). Never a
            // secret shown: both keys fold alike and are masked alike. Foundation's reader on Linux may merge them first.
            merged += max(0, ((value as? NSDictionary)?.count ?? dictionary.count) - dictionary.count)
            var out: [String: Any] = [:]
            for (key, item) in dictionary {
                if ProfileSecrets.isSecret(key) && (item is String || item is Data || item is [Any] || item is [String: Any])
                    || ProfileSecrets.isNumber(item) && ProfileSecrets.endsInASecretWord(key) {
                    out[key] = ProfileText.mask
                    masked += 1
                } else {
                    guard let walked = mask(item, depth: depth + 1) else { return nil }
                    out[key] = walked
                }
            }
            return out
        }
        if let array = value as? [Any] {
            guard depth < ProfileText.maximumDepth else { refusal = ProfileText.tooDeep; return nil }
            var out: [Any] = []
            for item in array {
                guard let walked = mask(item, depth: depth + 1) else { return nil }
                out.append(walked)
            }
            return out
        }
        if value is Data || (value as? String).map(ProfileSecrets.holdsPrivateKey) == true {
            masked += 1
            return ProfileText.mask
        }
        return value
    }
}

/// Which keys hold secrets. A key is read folded as the CSV denylist reads one (`ExportPolicy.fold` in Reports, which
/// this module can't import): compatibility-decomposed, lowercased, letters and numbers only, so case, a full-width
/// spelling, an invisible split or punctuation don't hide `password`; then without its numbers, so `WEP40Key` reads
/// `wepkey` and `VPNPIN2` ends in `pin` (verifier rounds 1 and 2). A PIN, a `PW` and a `PUK` are one by their own word or
/// the folded key's ending (`UserPIN`, `PINCode`, `pin_code`, `AdminPW`, `rootpw`, `pincode`, `PINs`), so `Shipping`,
/// `AllowPinning` and `Power` aren't.
enum ProfileSecrets {
    /// Phase 2a review L2 added the keys: a Wi-Fi or VPN pre-shared key (`PSK`; `SharedKey`, which holds `PreSharedKey`,
    /// so that stem would be dead: its mutant survived), and an encryption, client, access or licence key, which no stem
    /// held. Verifier round 2 added `ExportPolicy.sensitiveStems`' three this list lacked (`bypass`, the Activation Lock
    /// bypass code invariant 11 names first; `assertion`; `unlockpin`), which `ExportPolicyTests` now holds it to; an
    /// unlock or access code, which only a number was masked under; and a WEP key.
    static let stems = ["password", "passwd", "passphrase", "passcode", "pwd", "secret", "token", "credential", "privatekey",
                        "apikey", "recoverykey", "escrow", "challenge", "bearer", "jwt", "psk", "sharedkey", "encryptionkey",
                        "clientkey", "accesskey", "licensekey", "bypass", "assertion", "unlockpin", "unlockcode", "accesscode", "wepkey"]
    /// A secret by its own word, or as the folded key's ending: too short to find inside a longer word.
    static let secretWords = ["pin", "pw", "puk"]

    static func isSecret(_ key: String) -> Bool {
        let letters = letters(key)
        return stems.contains { Array(letters.utf8).firstRange(of: Array($0.utf8)) != nil }
            || endsIn(letters, secretWords)
            || words(key).contains { word in secretWords.contains { same(word, $0) || same(word, $0 + "s") } }
    }

    /// A last word that names the secret before it rather than a rule about it: `PINCode`, `PINNumber`, `PasscodeValue`
    /// (verifier round 1: a number under `PINValue` or `PasscodeValue` was shown).
    static let trailingWords = ["code", "number", "value"]
    /// A word that makes such a number a rule about a secret, not one: `MaxPIN`, `MinimumPasscode`.
    static let policyWords = ["max", "maximum", "min", "minimum", "age", "length", "history", "attempt", "attempts", "required", "complex",
                              "complexity"]

    /// Whether a number under `key` is a secret: when the folded key ends in a stem or one of `words` (`Passcode`,
    /// `UserPIN`, `UnlockCode`, `SharedSecret`, `LicenseKey`, `adminpw`), past a plural and trailing words (`PINs`,
    /// `PINCode`, `PasscodeValue`), and no policy word is in it (Phase 2a review L2: a numeric passcode, PIN or unlock code
    /// was shown, since only strings, data and containers were masked). Verifier round 2: read from the fold, not the
    /// last word, so `PassCode`, `pincode` and `SharedSecret` end in one, and a number under each was shown.
    static func endsInASecretWord(_ key: String) -> Bool {
        let words = words(key)
        guard !words.contains(where: { word in policyWords.contains { same($0, word) } }) else { return false }
        return endsIn(letters(key), stems + secretWords)
    }

    /// Whether `text` ends in one of `ends`, past any plural `s` and `trailingWords` at its end: `pins`, `pincode`,
    /// `devicepincodes`, `passcodevalue`.
    static func endsIn(_ text: String, _ ends: [String]) -> Bool {
        var pending = [Array(text.utf8)], seen: Set<[UInt8]> = []
        while let word = pending.popLast() {
            guard seen.insert(word).inserted, !word.isEmpty else { continue }
            func endsIn(_ end: String) -> Bool { word.suffix(end.utf8.count).elementsEqual(end.utf8) }
            if ends.contains(where: endsIn) { return true }
            if word.last == UInt8(ascii: "s") { pending.append(Array(word.dropLast())) }
            for trailing in trailingWords where word.count > trailing.utf8.count && endsIn(trailing) {
                pending.append(Array(word.dropLast(trailing.utf8.count)))
            }
        }
        return false
    }

    /// A plist number, not a flag: Foundation hands both over as `NSNumber`, a flag as a `CFBoolean`, whose `objCType`
    /// is `c` (checked on macOS 27: integers are `q` or `i`, reals `d`).
    static func isNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return !(String(cString: number.objCType) == "c" && value is Bool)
    }

    /// A private key, whatever its key: a PEM one (`-----BEGIN PRIVATE KEY-----`, and RSA, EC, ENCRYPTED, OPENSSH or PGP's
    /// `PRIVATE KEY BLOCK`, in any case), a PuTTY key file, or a JWK with its private member (`d`, or `k` for a symmetric
    /// key); as text, as base64 of the text, or in a `data:` URL. Under a key no stem names (`Identity`), a PEM key was
    /// shown (Phase 2a review L2), and the other forms and a `data:` URL until verifier round 2. A certificate's
    /// `-----BEGIN CERTIFICATE-----`, and a JWK without a private member, are public, and shown.
    static func holdsPrivateKey(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        if privateKey(in: bytes) || base64(bytes).map(privateKey) == true { return true }
        // `data:[<type>][;base64],<payload>`, its payload percent-encoded unless it says base64.
        let start = bytes.firstIndex { !ProfileText.isSpace($0) } ?? bytes.endIndex
        guard bytes[start...].map(ProfileText.lower).starts(with: Array("data:".utf8)),
              let comma = bytes[start...].firstIndex(of: UInt8(ascii: ",")) else { return false }
        let header = bytes[start..<comma].map(ProfileText.lower), payload = Array(bytes[(comma + 1)...])
        if header.firstRange(of: Array(";base64".utf8)) != nil { return base64(payload).map(privateKey) == true }
        return String(decoding: payload, as: UTF8.self).removingPercentEncoding.map { privateKey(in: Array($0.utf8)) } == true
    }

    /// Base64 (blanks allowed, padding optional) decoded, or nil when it isn't base64 of at least 16 characters.
    private static func base64(_ bytes: [UInt8]) -> [UInt8]? {
        let stripped = bytes.filter { !ProfileText.isSpace($0) }
        guard stripped.count >= 16, stripped.allSatisfy(ProfileText.isBase64) else { return nil }
        let padded = stripped + Array(repeating: UInt8(ascii: "="), count: (4 - stripped.count % 4) % 4)
        return Data(base64Encoded: Data(padded)).map(Array.init)
    }

    private static func privateKey(in bytes: [UInt8]) -> Bool {
        let lower = bytes.map(ProfileText.lower)
        var start = lower.startIndex
        while let begin = lower[start...].firstRange(of: Array("-----begin ".utf8)) {
            let label = lower[begin.upperBound...].prefix { $0 != UInt8(ascii: "-") && $0 != 0x0A && $0 != 0x0D }
            if label.firstRange(of: Array("private key".utf8)) != nil { return true }
            start = begin.upperBound
        }
        if lower.firstRange(of: Array("putty-user-key-file-".utf8)) != nil, lower.firstRange(of: Array("private-lines:".utf8)) != nil { return true }
        return member("kty", in: bytes) && (member("d", in: bytes) || member("k", in: bytes))
    }

    /// Whether JSON text has a member `name` (`"name"`, blanks, `:`), by its bytes: JSON's names are case-sensitive.
    private static func member(_ name: String, in bytes: [UInt8]) -> Bool {
        let quoted = Array("\"\(name)\"".utf8)
        var start = bytes.startIndex
        while let found = bytes[start...].firstRange(of: quoted) {
            var index = found.upperBound
            while index < bytes.endIndex, ProfileText.isSpace(bytes[index]) { index += 1 }
            if index < bytes.endIndex, bytes[index] == UInt8(ascii: ":") { return true }
            start = found.lowerBound + 1
        }
        return false
    }

    /// Words compared by their bytes, as everything here is.
    private static func same(_ word: String, _ other: String) -> Bool { word.utf8.elementsEqual(other.utf8) }

    static func fold(_ key: String) -> String {
        let scalars = key.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
        return String(String.UnicodeScalarView(scalars.filter(isLetterOrNumber)))
    }

    /// The fold without its numbers: what the stems and endings are found in.
    static func letters(_ key: String) -> String {
        String(String.UnicodeScalarView(fold(key).unicodeScalars.filter { !isNumeral($0) }))
    }

    /// A key's words, lowercased: split at anything not a letter or number but a mark or an invisible format character
    /// (which are dropped, as the fold drops them), before a capital that follows a lowercase letter, before the
    /// last capital of a run that a lowercase letter follows (`PINCode` is `pin`, `code`) unless that letter is a plural
    /// `s` ending the word (`PINs` is `pins`, `UserPWs` is `user`, `pws`: verifier round 2, they were `pi`, `ns` and
    /// `user`, `p`, `ws`), and where letters meet numbers (`DevicePIN2` is `device`, `pin`, `2`: verifier round 1, it was
    /// `device`, `pin2`, no PIN).
    static func words(_ key: String) -> [String] {
        let scalars = Array(key.decomposedStringWithCompatibilityMapping.unicodeScalars)
        var words: [String] = [], word = String.UnicodeScalarView()
        func end() {
            if !word.isEmpty { words.append(String(word).lowercased()) }
            word = String.UnicodeScalarView()
        }
        for (index, scalar) in scalars.enumerated() {
            guard isLetterOrNumber(scalar) else {
                switch scalar.properties.generalCategory {
                case .format, .nonspacingMark, .spacingMark, .enclosingMark: continue
                default: end(); continue
                }
            }
            if let previous = word.last {
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                let afterNext = index + 2 < scalars.count ? scalars[index + 2] : nil
                let plural = next == "s" && afterNext?.properties.isLowercase != true
                let upper = scalar.properties.isUppercase
                if upper && previous.properties.isLowercase { end() }
                if upper && previous.properties.isUppercase, let next, next.properties.isLowercase, !plural { end() }
                if isNumeral(scalar) != isNumeral(previous) { end() }
            }
            word.append(scalar)
        }
        end()
        return words
    }

    private static func isNumeral(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }
}
