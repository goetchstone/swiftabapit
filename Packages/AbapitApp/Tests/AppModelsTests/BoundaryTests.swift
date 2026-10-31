import Foundation
import Testing
import TestSupport

/// The screen models sit outside AbapitKit, in their own package, so the compiler refuses every `package`
/// declaration (a secret's bytes, the Vault's reads and signatures, the read and credential builders, the HTTP
/// client): they see what the app sees. In AbapitKit a source scan held that line, and the review found it missed a
/// read through implicit `self` (Phase 1b review, models verifier round 4); `scripts/check_graph.py` now holds this
/// package to AbapitKit's products and refuses `unsafeFlags`, which could name AbapitKit's package and reopen it.
/// What access control can't stop is left here: reflection reads stored properties whatever their access, and
/// reinterpreting memory forges values the type system guards.
@Suite("Screen-model boundary")
struct BoundaryTests {
    static let directory = "Packages/AbapitApp/Sources/AppModels"

    static let reflection = ["Mirror", "dump", "reflecting", "customMirror", "unsafeBitCast", "unsafeDowncast", "withMemoryRebound",
                             "assumingMemoryBound", "bindMemory", "withUnsafeBytes", "unsafeAddress", "Unmanaged"]

    @Test func theScanSeesTheModels() throws {
        let files = try SourceScan.swiftFiles(in: Self.directory).map(\.path)
        #expect(Set(files).isSuperset(of: ["OrgsModel.swift", "DevicesModel.swift", "DeviceDetailModel.swift"].map { "\(Self.directory)/\($0)" }))
    }

    @Test func theScreenModelsUseNoReflectionOrRawMemory() throws {
        #expect(try SourceScan.files(in: Self.directory, naming: Self.reflection).isEmpty)
    }

    /// `@testable` would compile in Debug and reopen `internal` declarations; Release refuses it, but a Debug build
    /// is what the operator runs from Xcode.
    @Test func theScreenModelsImportNothingTestably() throws {
        #expect(try SourceScan.files(in: Self.directory, matching: ["@testable", "@_spi", "@_implementationOnly"]).isEmpty)
    }

    /// Raw memory reads a key's or a secret's stored bytes whatever their access: `withUnsafePointer(to: key)` and
    /// `UnsafeRawPointer.load(as:)` returned both, with every check green (integration review H1).
    static let rawMemory = ["Unsafe", "unsafe", "Unmanaged", "MemoryLayout"]

    @Test func theScreenModelsTouchNoRawMemory() throws {
        #expect(try SourceScan.files(in: Self.directory, matching: Self.rawMemory).isEmpty)
        #expect(SourceScan.mentions(SourceScan.File(path: "x.swift", text: "withUnsafePointer(to: key) { UnsafeRawPointer($0).load(as: Data.self) }"),
                                    Self.rawMemory))
    }

    /// What the screen models may import: Foundation, Observation and their five AbapitKit products. `import Network` and
    /// `import SQLite3` passed every check once the module's list was dropped with the move (integration review M3).
    @Test func theScreenModelsImportOnlyTheirModules() throws {
        let allowed: Set = ["Foundation", "Observation", "AppleBusiness", "AppleModels", "Orgs", "Vault", "Reports"]
        for file in try SourceScan.swiftFiles(in: Self.directory) {
            let extra = Set(SourceScan.imports(of: file)).subtracting(allowed)
            #expect(extra.isEmpty, "\(file.path) imports \(extra.sorted())")
        }
    }

    /// The scan finds a use in each spelling it is there to catch.
    @Test func theScanFindsAUse() {
        for code in ["let m = Mirror(reflecting: key)", "dump(key)", "_ = String(reflecting: key)", "_ = unsafeBitCast(x, to: Int.self)"] {
            #expect(SourceScan.names(SourceScan.File(path: "x.swift", text: code), Self.reflection), "\(code)")
        }
        #expect(!SourceScan.names(SourceScan.File(path: "x.swift", text: "// Mirror(reflecting: key)\nlet dumped = 1"), Self.reflection))
    }

    /// A custom setting's profile as Apple sent it, and what holds it, are `package` (Phase 2a review M2), so the compiler
    /// refuses them here and in the app; the app side shows a profile only through `profileText`, masked. This keeps
    /// the names out of both should one be made reachable again.
    static let rawProfile = ["configurationProfile", "received", "withholding", "withholdingProfile"]

    @Test func theAppSideNeverNamesTheRawProfile() throws {
        #expect(try SourceScan.swiftFiles(in: "App").count >= 5, "the scan sees the app")
        for directory in [Self.directory, "App"] {
            #expect(try SourceScan.files(in: directory, naming: Self.rawProfile).isEmpty, "\(directory)")
        }
        #expect(SourceScan.names(SourceScan.File(path: "x.swift", text: "let raw = configuration.customSettings?.configurationProfile"), Self.rawProfile))
        #expect(!SourceScan.names(SourceScan.File(path: "x.swift", text: "// configurationProfile\nlet shown = settings.profileText"), Self.rawProfile))
    }

    /// The compiler's half of the line above: every declaration in AppleModels of what holds the profile as Apple sent it
    /// (`Configuration.received`, `CustomSettingsValues.received` and `.configurationProfile`) is `package` and only that,
    /// so naming one here or in the app is a compile error. Widened to `public`, or moved into a `public extension`, each
    /// left every test green with only the name scan behind it (verifier round 1).
    @Test func whatHoldsTheRawProfileStaysPackage() throws {
        let declaration = try Regex(#"^\s*(.*?)\b(?:let|var)\s+(received|configurationProfile)\b"#)
        func declarations(_ code: String) -> [String] {
            code.split(separator: "\n").compactMap { line in
                (try? declaration.firstMatch(in: String(line))).flatMap { $0 }.map { match in
                    let modifiers = match.output[1].substring.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    return "\(modifiers) \(match.output[2].substring ?? "")"
                }
            }
        }
        let files = try SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/AppleModels")
        #expect(files.contains { $0.path.hasSuffix("/AppleModels/Content.swift") })
        let found = files.flatMap { declarations(SourceScan.code($0.text, strings: false)) }
        #expect(found == ["package received", "package received", "package configurationProfile"], "\(found)")
        // The scan reads what a widening would write, and not a comment.
        #expect(declarations("    public let received: Resource\n    var configurationProfile: String? { nil }") == ["public received", " configurationProfile"])
        #expect(declarations(SourceScan.code("/// package let received\n", strings: false)).isEmpty)
    }

    /// Every line of code in AbapitKit that names the profile as Apple sent it (`received`, `configurationProfile`), as it
    /// reads with its blanks collapsed: the modifiers above hold the three declarations, and this holds what reads them,
    /// so a public accessor of another name (`public var rawText: String? { configurationProfile }`, `public extension
    /// Configuration { var sent: Resource { received } }`), in any AbapitKit module, fails here (verifier round 2: each
    /// left every test green). A line that must read the profile (Phase 5's writer) is added here, where review sees it.
    static let rawReaders = [
        "Packages/AbapitKit/Sources/AppleModels/Content.swift: package let received: Resource",
        "Packages/AbapitKit/Sources/AppleModels/Content.swift: received = resource",
        #"Packages/AbapitKit/Sources/AppleModels/Content.swift: public var customSettings: CustomSettingsValues? { received.attributes["customSettingsValues"]?.object.map(CustomSettingsValues.init) }"#,
        #"Packages/AbapitKit/Sources/AppleModels/Content.swift: switch received.attributes["customSettingsValues"] {"#,
        "Packages/AbapitKit/Sources/AppleModels/Content.swift: package let received: JSONObject",
        "Packages/AbapitKit/Sources/AppleModels/Content.swift: received = object",
        #"Packages/AbapitKit/Sources/AppleModels/Content.swift: package var configurationProfile: String? { received.string("configurationProfile") }"#,
        #"Packages/AbapitKit/Sources/AppleModels/Content.swift: public var filename: String? { received.string("filename") }"#,
        "Packages/AbapitKit/Sources/AppleModels/Content.swift: public var profileText: ProfileText? { configurationProfile.map(ProfileText.init) }",
    ]

    /// The lines of `file`'s code that name any of `names` whole, comments and string literals not counting, each with its
    /// literals as written and its blanks collapsed.
    static func lines(of file: SourceScan.File, naming names: [String]) -> [String] {
        let code = SourceScan.code(file.text, strings: false).split(separator: "\n", omittingEmptySubsequences: false)
        let shown = SourceScan.code(file.text, strings: true).split(separator: "\n", omittingEmptySubsequences: false)
        return zip(code, shown).compactMap { code, shown in
            guard SourceScan.names(SourceScan.File(path: file.path, text: String(code)), names) else { return nil }
            return "\(file.path): " + shown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    @Test func onlyTheListedLinesReadTheRawProfile() throws {
        let files = try SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources")
        #expect(files.count >= 50 && files.contains { $0.path.hasSuffix("/AppleBusiness/AppleClient.swift") }, "the scan sees AbapitKit")
        let found = files.flatMap { Self.lines(of: $0, naming: ["received", "configurationProfile"]) }
        #expect(found == Self.rawReaders, "\(found.joined(separator: "\n"))")
        // It reads the accessors the verifier added, and not a comment or a string naming either.
        let mutants = SourceScan.File(path: "x.swift", text: """
            public extension Configuration { var sent: Resource { received } }
                public var rawText: String? {
                    `configurationProfile`
                }
            // received
            let key = "configurationProfile"
            """)
        #expect(Self.lines(of: mutants, naming: ["received", "configurationProfile"])
                == ["x.swift: public extension Configuration { var sent: Resource { received } }", "x.swift: `configurationProfile`"])
    }
}
