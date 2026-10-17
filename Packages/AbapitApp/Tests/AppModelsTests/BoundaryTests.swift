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

    /// The scan finds a use in each spelling it is there to catch.
    @Test func theScanFindsAUse() {
        for code in ["let m = Mirror(reflecting: key)", "dump(key)", "_ = String(reflecting: key)", "_ = unsafeBitCast(x, to: Int.self)"] {
            #expect(SourceScan.names(SourceScan.File(path: "x.swift", text: code), Self.reflection), "\(code)")
        }
        #expect(!SourceScan.names(SourceScan.File(path: "x.swift", text: "// Mirror(reflecting: key)\nlet dumped = 1"), Self.reflection))
    }
}
