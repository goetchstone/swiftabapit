import Foundation
import Testing
import TestSupport

/// What every scan rests on: it reads the whole of what the app and the package compile. Phase 1b gates verifier
/// round 1 hid code from every scan twice: behind a bare regex literal the lexer misread, and in an Objective-C file
/// the scans never opened.
@Suite("Scanned tree")
struct TreeTests {
    /// Every root a scan reads; together they are everything the app compiles.
    static let roots = DebugOnlyTests.roots

    /// The lexer reads every file as Swift does. A bare regex literal is the one construct it doesn't follow, and
    /// `/\/*/` before `URLSession.shared.upload(…)` hid the upload from `RouteTests`, which a line scan had caught.
    @Test func everyFileReadsAsSwift() throws {
        var seen: [String: Int] = [:]
        for root in Self.roots {
            for file in try SourceScan.swiftFiles(in: root) {
                seen[root, default: 0] += 1
                let spots = SourceScan.unreadable(file)
                #expect(spots.isEmpty, "\(spots)")
            }
        }
        // Every root, each read: App/ alone holds a screen a regex could hide a fetch in, and the screen models' package
        // holds three files (a scan that read none of them would pass vacuously).
        #expect(Set(Self.roots) == ["App", "Packages/AbapitKit/Sources", "Packages/AbapitApp/Sources"])
        let least = ["App": 10, "Packages/AbapitKit/Sources": 10, "Packages/AbapitApp/Sources": 3]
        #expect(Self.roots.allSatisfy { seen[$0, default: 0] >= least[$0, default: 10] }, "the scan reads \(seen)")
    }

    /// What each root may hold: Swift, which the scans read, and in App/ the inert files an asset or string catalog
    /// needs. App/ is a synchronized folder, so Xcode compiles any source put there: `App/Leak.m`, whose `+load`
    /// opened an NSURLSession, built into Release past every scan and the gate.
    static let kinds: [String: Set<String>] = ["App": ["swift", "json", "png", "pdf", "svg", "xcstrings"], "Packages/AbapitKit/Sources": ["swift"],
                                               "Packages/AbapitApp/Sources": ["swift"]]

    /// Whether `path` (a file under `root`) is one the scans can't vouch for. Finder's `.DS_Store` is ignored.
    static func refused(_ path: String, in root: String) -> Bool {
        let url = URL(filePath: path)
        return url.lastPathComponent != ".DS_Store" && !(kinds[root] ?? []).contains(url.pathExtension)
    }

    @Test func onlySwiftIsCompiled() throws {
        #expect(Set(Self.kinds.keys) == Set(Self.roots))
        for root in Self.roots {
            let base = Fixtures.repoRoot.appending(path: root)
            let paths = FileManager.default.subpaths(atPath: base.path) ?? []
            #expect(paths.contains { $0.hasSuffix(".swift") }, "nothing seen under \(root)")
            for path in paths {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: base.appending(path: path).path, isDirectory: &directory), !directory.boolValue else {
                    continue
                }
                #expect(!Self.refused(path, in: root), "\(root)/\(path): the scans read Swift only, and Xcode or SwiftPM may compile this")
            }
        }
    }

    /// The links at and under `base`, relative to it (`.` for `base` itself). SwiftPM compiles a target's sources
    /// through a linked folder, and `FileManager.subpaths` lists the link but not what it holds, so no scan read it:
    /// `Sources/AppleBusiness/Linked -> ../../../../Extra` holding `URLSession.shared.upload(…)` passed every test
    /// (Phase 1b gates verifier round 2). Git commits a link as a link (mode 120000), so it can arrive in a pull request.
    static func links(under base: URL) -> [String] {
        let inside = (FileManager.default.subpaths(atPath: base.path) ?? []).filter { isLink(base.appending(path: $0)) }
        return ((isLink(base) ? ["."] : []) + inside).sorted()
    }

    static func isLink(_ url: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }

    /// The links a scan of `root` (relative to `base`) reads through: a folder above it (`Packages` linked elsewhere),
    /// `root` itself, or anything under it.
    static func links(reading root: String, from base: URL) -> [String] {
        let parts = root.split(separator: "/").map(String.init)
        let above = (1..<max(parts.count, 1)).map { parts.prefix($0).joined(separator: "/") }.filter { isLink(base.appending(path: $0)) }
        return above + links(under: base.appending(path: root)).map { $0 == "." ? root : "\(root)/\($0)" }
    }

    @Test func nothingIsALink() throws {
        for root in Self.roots {
            let found = Self.links(reading: root, from: Fixtures.repoRoot)
            #expect(found.isEmpty, "\(found): a link, which the scans don't follow")
        }
    }

    @Test func aLinkIsFound() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: "abapit-links-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        for folder in ["Target/Sub", "Extra"] { try manager.createDirectory(at: base.appending(path: folder), withIntermediateDirectories: true) }
        for file in ["Target/A.swift", "Extra/F.swift"] { try Data().write(to: base.appending(path: file)) }
        try manager.createSymbolicLink(atPath: base.appending(path: "Target/Linked").path, withDestinationPath: "../Extra")
        try manager.createSymbolicLink(atPath: base.appending(path: "Target/Sub/F.swift").path, withDestinationPath: "../../Extra/F.swift")
        try manager.createSymbolicLink(atPath: base.appending(path: "Root").path, withDestinationPath: "Target")
        #expect(Self.links(under: base.appending(path: "Target")) == ["Linked", "Sub/F.swift"])
        #expect(Self.links(under: base.appending(path: "Root")).contains("."))
        #expect(Self.links(under: base.appending(path: "Extra")).isEmpty)
        // A folder above a root, the root, and what it holds.
        try manager.createDirectory(at: base.appending(path: "Real/Kit/Sources"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: base.appending(path: "Linked").path, withDestinationPath: "Real")
        #expect(Self.links(reading: "Linked/Kit/Sources", from: base) == ["Linked"])
        #expect(Self.links(reading: "Root", from: base) == ["Root", "Root/Linked", "Root/Sub/F.swift"])
        #expect(Self.links(reading: "Real/Kit/Sources", from: base).isEmpty)
    }

    /// Sources Xcode or SwiftPM would compile or link, and what a catalog holds.
    @Test func whatIsRefused() {
        for path in ["Leak.m", "Leak.mm", "leak.c", "leak.cpp", "leak.s", "Shader.metal", "libleak.a", "leak.dylib", "Leak.framework/Leak",
                     "Main.xib", "Main.storyboard", "Intents.intentdefinition", "Model.xcdatamodeld/Model.xcdatamodel/contents", "Info.plist",
                     ".Leak.m", "Leak.M"] {
            #expect(Self.refused(path, in: "App"), "\(path)")
        }
        for path in ["Screens/DevicesView.swift", "Assets.xcassets/AppIcon.appiconset/Contents.json", "Assets.xcassets/AppIcon.appiconset/icon.png",
                     "Localizable.xcstrings", ".DS_Store", "Screens/.DS_Store"] {
            #expect(!Self.refused(path, in: "App"), "\(path)")
        }
        #expect(Self.refused("HTTPCore/leak.c", in: "Packages/AbapitKit/Sources"))
        #expect(Self.refused("HTTPCore/data.json", in: "Packages/AbapitKit/Sources"))
        #expect(!Self.refused("HTTPCore/Transport.swift", in: "Packages/AbapitKit/Sources"))
    }
}
