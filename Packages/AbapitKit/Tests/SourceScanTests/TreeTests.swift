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

    /// Xcode compiles what the project's synchronized folders and file references name: exactly `App/`, in one
    /// target, with no phase that runs a script or copies a file. A second synchronized folder (`Extras/`, holding
    /// `URLSession.shared.upload`) compiled into the app and no scan read it (failure-log 2026-11-18): the roots above
    /// are everything the app compiles only while this holds.
    @Test func theProjectCompilesOnlyTheAppFolder() throws {
        let project = try String(contentsOf: Fixtures.repoRoot.appending(path: "SwiftAbapit.xcodeproj/project.pbxproj"), encoding: .utf8)
        func count(_ needle: String) -> Int { project.components(separatedBy: needle).count - 1 }
        let groups = project.matches(of: #/isa = PBXFileSystemSynchronizedRootGroup;\s*path = ([^;]+);/#).map { String($0.output.1) }
        #expect(groups == ["App"], "\(groups)")
        #expect(count("isa = PBXFileSystemSynchronizedRootGroup;") == 1)
        let synced = try #require(project.firstMatch(of: #/fileSystemSynchronizedGroups = \(([^)]*)\);/#)).output.1
        let listed = synced.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        #expect(listed.count == 1 && listed.first?.hasSuffix("/* App */") == true, "\(listed)")
        #expect(count("fileSystemSynchronizedGroups = (") == 1)
        #expect(count("isa = PBXNativeTarget;") == 1)
        for refused in ["PBXShellScriptBuildPhase", "PBXBuildRule", "PBXCopyFilesBuildPhase", "PBXAggregateTarget", "PBXLegacyTarget",
                        "PBXFileSystemSynchronizedBuildFileExceptionSet", "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet",
                        "PBXReferenceProxy", "PBXContainerItemProxy", "PBXTargetDependency"] {
            #expect(!project.contains(refused), "\(refused)")
        }
        let files = project.matches(of: #/isa = PBXFileReference;[^\n]*?path = "?([^";]+)"?;/#).map { String($0.output.1) }.sorted()
        #expect(files == ["Base.xcconfig", "abapit-Team.entitlements", "abapit.app", "abapit.entitlements"], "\(files)")
        #expect(count("isa = PBXFileReference;") == 4)
        #expect(Self.whereTheRootsResolve(project) == [], "\(Self.whereTheRootsResolve(project))")
    }

    /// Where `App` resolves: the project's directory and root are empty, the main group has no `path`, and `App` is
    /// relative to its group. Each was a way to make the one group `App` mean another folder (`projectDirPath = Extras;`)
    /// with the name check above still green. Returns what is wrong; empty when nothing is.
    static func whereTheRootsResolve(_ project: String) -> [String] {
        var faults: [String] = []
        func lines(_ key: String) -> [String] { project.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("\(key) =") } }
        if lines("projectDirPath") != ["projectDirPath = \"\";"] { faults.append("projectDirPath \(lines("projectDirPath"))") }
        if lines("projectRoot") != ["projectRoot = \"\";"] { faults.append("projectRoot \(lines("projectRoot"))") }
        func block(_ id: String) -> String? {
            guard let start = project.range(of: "\n\t\t\(id) "), let end = project.range(of: "\n\t\t};", range: start.upperBound..<project.endIndex) else { return nil }
            return String(project[start.upperBound..<end.lowerBound])
        }
        if let main = project.firstMatch(of: #/mainGroup = ([0-9A-F]+);/#).map({ String($0.output.1) }), let group = block(main) {
            if group.contains("\n\t\t\tpath =") { faults.append("the main group has a path") }
            if !group.contains("\n\t\t\tsourceTree = \"<group>\";") { faults.append("the main group's sourceTree") }
        } else {
            faults.append("no main group")
        }
        if let app = project.firstMatch(of: #/([0-9A-F]+) \/\* App \*\/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;/#).map({ String($0.output.1) }),
           let group = block(app) {
            if !group.contains("\n\t\t\tsourceTree = \"<group>\";") { faults.append("App's sourceTree") }
            if !group.contains("\n\t\t\tpath = App;") { faults.append("App's path") }
        } else {
            faults.append("no App group")
        }
        return faults
    }

    /// Each way to point the one `App` group elsewhere, made on the real project's text in memory (never on the file).
    @Test(arguments: [
        ("projectDirPath = \"\";", "projectDirPath = Extras;"),
        ("projectRoot = \"\";", "projectRoot = Extras;"),
        ("\t\t\tchildren = (\n\t\t\t\t5AB000000000000000000010 /* App */,", "\t\t\tpath = Extras;\n\t\t\tchildren = (\n\t\t\t\t5AB000000000000000000010 /* App */,"),
        ("\t\t\tpath = App;\n\t\t\tsourceTree = \"<group>\";", "\t\t\tpath = App;\n\t\t\tsourceTree = DERIVED_FILE_DIR;"),
    ])
    func theRootsMustResolveToTheAppFolder(_ original: String, _ mutant: String) throws {
        let project = try String(contentsOf: Fixtures.repoRoot.appending(path: "SwiftAbapit.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(Self.whereTheRootsResolve(project) == [])
        #expect(project.components(separatedBy: original).count == 2, "the project no longer holds: \(original)")
        #expect(!Self.whereTheRootsResolve(project.replacingOccurrences(of: original, with: mutant)).isEmpty, "\(mutant)")
    }

    /// The Release gate's import pattern, read from `scripts/check_app.sh` and run on symbols a build carries: the
    /// names a review found past it (`LSOpenCFURLRef`, SwiftUI's `WebView`, which compiles to `_WebKit_SwiftUI`).
    @Test func theGatePatternRefusesTheHostRoutes() throws {
        let script = try String(contentsOf: Fixtures.repoRoot.appending(path: "scripts/check_app.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.contains("NSSharingService") && $0.contains("grep -E") })
        let pattern = try #require(line.firstMatch(of: #/grep -E '([^']+)'/#)).output.1
        let regex = try NSRegularExpression(pattern: String(pattern))
        func refuses(_ symbol: String) -> Bool { regex.firstMatch(in: symbol, range: NSRange(symbol.startIndex..., in: symbol)) != nil }
        for symbol in ["_socket", "_connect", "_getaddrinfo", "_OBJC_CLASS_$_NSHost", "_OBJC_CLASS_$_NSStream", "_LSOpenCFURLRef",
                       "_LSOpenURLsWithRole", "_$s15_WebKit_SwiftUI7WebViewV", "_OBJC_CLASS_$_WKWebView", "_OBJC_CLASS_$_NSWorkspace"] {
            #expect(refuses(symbol), "\(symbol)")
        }
        for symbol in ["_connectionFailed", "_$s7SwiftUI4ViewP", "_LSSharedFileList", "_OBJC_CLASS_$_NSURLSession"] {
            #expect(!refuses(symbol), "\(symbol)")
        }
    }

    /// What each root may hold: Swift, which the scans read, and in App/ the inert files an asset or string catalog
    /// needs. App/ is a synchronized folder, so Xcode compiles any source put there: `App/Leak.m`, whose `+load`
    /// opened an NSURLSession, built into Release past every scan and the gate.
    static let kinds: [String: Set<String>] = ["App": ["swift", "json", "png", "pdf", "svg", "xcstrings"], "Packages/AbapitKit/Sources": ["swift"],
                                               "Packages/AbapitApp/Sources": ["swift"]]

    /// Whether `path` (a file under `root`) is one the scans can't vouch for. Finder's `.DS_Store` is ignored.
    static func refused(_ path: String, in root: String) -> Bool {
        let url = URL(filePath: path)
        // A catalog named InfoPlist localizes the Info.plist (it ships as InfoPlist.strings, which the Release gate refuses).
        if url.deletingPathExtension().lastPathComponent == "InfoPlist" { return true }
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
                     ".Leak.m", "Leak.M", "InfoPlist.xcstrings", "Screens/InfoPlist.xcstrings"] {
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
