import AppKit
import Foundation

/// The env-var screenshot harness (plan §6.5), debug builds only. Adapted from SwiftGamGui
/// App/Spikes.swift:73-115 @ bfdb494. `ABAPIT_SNAPSHOT=<name>.png` renders the window's screen pane to a
/// PNG and quits. The App Sandbox lets the app write only inside its container, so the picture goes to the
/// container's temporary folder under that file name, the path is printed (`snapshot: <path>`), and
/// `scripts/screenshots.sh` moves it out; `ABAPIT_SCREEN` picks the section, `ABAPIT_SELECT` a row, `ABAPIT_WINDOW` the size
/// (`WIDTHxHEIGHT` or `smallest`) and `ABAPIT_DEMO=1` fills it from the demo org (strict stubs, memory
/// only). Environment variables, not launch arguments: AppKit reads `-key value` arguments as defaults,
/// and a bare path left over is taken as a document to open. CI runs it (`scripts/screenshots.sh`); it
/// never runs on the operator's screen.
enum Snapshots {
    static func runIfRequested() async {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["ABAPIT_SNAPSHOT"] else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        await sizeWindow(environment["ABAPIT_WINDOW"])
        await snapshot(to: URL.temporaryDirectory.appending(path: URL(filePath: name).lastPathComponent))
        #endif
    }

    #if DEBUG
    /// What the screen's pane must have beyond what it needs in the smallest window, with the sidebar and
    /// any inspector at their widest (SwiftGamGui's crash came with 84 pt to spare).
    static let spareWidth = 100.0

    static func snapshot(to file: URL) async {
        let selecting = ProcessInfo.processInfo.environment["ABAPIT_SELECT"] != nil
        try? await Task.sleep(for: .seconds(selecting ? 4 : 1.5))
        let window = NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }
        guard let content = window?.contentView else {
            print("snapshot: no window")
            exit(EXIT_FAILURE)
        }
        let smallest = ProcessInfo.processInfo.environment["ABAPIT_WINDOW"] == "smallest"
        if smallest {
            widenSideColumns(in: content)
            try? await Task.sleep(for: .seconds(1))
        }
        let sheet = window?.attachedSheet?.contentView
        let view = sheet ?? splitViews(in: content).first?.arrangedSubviews.last ?? content
        // The sidebar floats over the screen's pane, which starts beneath it: crop to the safe area.
        var rect = view.bounds
        if sheet == nil {
            let toolbar = min(view.safeAreaInsets.top, rect.height)
            let sidebar = min(view.safeAreaInsets.left, rect.width)
            rect.size.height -= toolbar
            rect.size.width -= sidebar
            rect.origin.x += sidebar
            if view.isFlipped { rect.origin.y += toolbar }
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            print("snapshot: nothing to draw")
            exit(EXIT_FAILURE)
        }
        view.cacheDisplay(in: rect, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: file)
            print("snapshot: \(file.path)")
        } catch {
            print("snapshot: \(error)")
            exit(EXIT_FAILURE)
        }
        // After the image, so CI keeps a picture of the layout that failed.
        let tooNarrow = columnsTooNarrow(in: content, spare: smallest ? spareWidth : 0)
        if !tooNarrow.isEmpty {
            print("snapshot: a column is narrower than its content's minimum: \(tooNarrow.joined(separator: "; "))")
            exit(EXIT_FAILURE)
        }
        let outside = controlsOutsideTheWindow(in: content)
        if !outside.isEmpty {
            print("snapshot: a control reaches past the window's edge: \(outside.joined(separator: "; "))")
            exit(EXIT_FAILURE)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            print("snapshot: the app didn't quit within 10 s of its picture")
            exit(EXIT_FAILURE)
        }
        NSApp.terminate(nil)
    }

    /// AppKit controls that reach past the window's left or right edge: a page wider than its pane is
    /// clipped on both sides, which `columnsTooNarrow` can't see. A table's cells scroll and are left out.
    static func controlsOutsideTheWindow(in content: NSView) -> [String] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        func inTable(_ view: NSView) -> Bool {
            var ancestor = view.superview
            while let next = ancestor {
                if next is NSTableView { return true }
                ancestor = next.superview
            }
            return false
        }
        let bounds = content.bounds
        return descendants(content).compactMap { view in
            guard let control = view as? NSControl, !control.isHiddenOrHasHiddenAncestor, control.alphaValue > 0,
                  !inTable(control) else { return nil }
            let frame = control.convert(control.bounds, to: content)
            guard frame.width > 0, frame.minX < bounds.minX - 1 || frame.maxX > bounds.maxX + 1 else { return nil }
            return "\(type(of: control)) from x \(Int(frame.minX)) to \(Int(frame.maxX)), the window \(Int(bounds.width)) wide"
        }
    }

    /// Every split view column whose content needs more width than it has, and the screen's pane when it
    /// has less than `spare` beyond that.
    static func columnsTooNarrow(in content: NSView, spare: Double) -> [String] {
        var problems: [String] = []
        for (s, split) in splitViews(in: content).enumerated() {
            for (c, column) in split.arrangedSubviews.enumerated() where !column.isHidden {
                let needs = column.fittingSize.width.rounded(.up), has = column.frame.width
                let wanted = s == 0 && c == split.arrangedSubviews.count - 1 ? spare : 0
                print("layout: split \(s) column \(c): \(Int(has)) pt wide, needs \(Int(needs))")
                if needs + wanted > has + 0.5 {
                    problems.append("split \(s) column \(c) needs \(Int(needs)) pt and \(Int(wanted)) to spare, has \(Int(has))")
                }
            }
        }
        return problems
    }

    static func splitViews(in view: NSView) -> [NSSplitView] {
        (view is NSSplitView ? [view as! NSSplitView] : []) + view.subviews.flatMap(splitViews(in:))
    }

    /// `WIDTHxHEIGHT`, or `smallest`: the window's minimum, with the sidebar and any inspector then dragged
    /// to their widest — the tightest layout an operator can make.
    static func sizeWindow(_ spec: String?) async {
        guard let spec else { return }
        let parts = spec.split(separator: "x")
        let size = parts.count == 2 ? Double(parts[0]).flatMap { w in Double(parts[1]).map { NSSize(width: w, height: $0) } } : nil
        guard spec == "smallest" || size != nil else {
            print("snapshot: ABAPIT_WINDOW is WIDTHxHEIGHT or smallest, not \(spec)")
            return
        }
        for _ in 0..<50 {
            if let window = NSApp.windows.first(where: \.isVisible) {
                window.setContentSize(size ?? window.contentMinSize)
                try? await Task.sleep(for: .milliseconds(300))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("snapshot: no window to size")
    }

    static func widenSideColumns(in content: NSView) {
        for split in splitViews(in: content) {
            guard let items = (split.delegate as? NSSplitViewController)?.splitViewItems else { continue }
            split.autosaveName = nil
            for (index, item) in items.enumerated() {
                switch item.behavior {
                case .sidebar where index < items.count - 1: split.setPosition(split.bounds.width, ofDividerAt: index)
                case .inspector where index > 0: split.setPosition(0, ofDividerAt: index - 1)
                default: break
                }
            }
        }
    }
    #endif
}
