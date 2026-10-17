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
        // Both roots, each read: App/ alone holds a screen a regex could hide a fetch in.
        #expect(Set(Self.roots) == ["App", "Packages/AbapitKit/Sources"])
        #expect(Self.roots.allSatisfy { seen[$0, default: 0] > 10 }, "the scan reads \(seen)")
    }

    /// What each root may hold: Swift, which the scans read, and in App/ the inert files an asset or string catalog
    /// needs. App/ is a synchronized folder, so Xcode compiles any source put there: `App/Leak.m`, whose `+load`
    /// opened an NSURLSession, built into Release past every scan and the gate.
    static let kinds: [String: Set<String>] = ["App": ["swift", "json", "png", "pdf", "svg", "xcstrings"], "Packages/AbapitKit/Sources": ["swift"]]

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
