#!/usr/bin/env python3
"""Self-test of scripts/check_graph.py: the graph check must refuse every mutant manifest below, and say why.

A check that was never seen to fail can't hold (RULE-FEEDBACK 2026-10-16, "a check that was never seen to fail").
It copies scripts/check_graph.py and Packages/ (without build folders) into a temporary tree with the same layout
(check_graph.py finds the repo from its own path), changes one manifest in one way, and runs the copy of the check.
A mutant counts as refused only when the check exits 1 AND prints every reason named beside it, so a refusal for
another reason is a failure of this self-test. There is one mutant for each refusal the check can print. Nothing
is built: `swift package dump-package` only evaluates a manifest.

    python3 -I scripts/check_graph_selftest.py
    CHECK_GRAPH=path/to/another/check_graph.py python3 scripts/check_graph_selftest.py   (to see it fail on a weakened check)
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = Path(os.environ.get("CHECK_GRAPH", ROOT / "scripts" / "check_graph.py"))
KIT, APP = "AbapitKit", "AbapitApp"

# Text of the manifests this self-test changes. If a manifest is rewritten, a mutant stops applying and says so.
SETTINGS = '    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),\n]'
ASSIST = '.target(name: "Assist", dependencies: ["Planners", "Reports"], swiftSettings: settings)'
WIRE = '.target(name: "Wire", swiftSettings: settings)'
WIRE_TESTS = '.testTarget(name: "WireTests", dependencies: ["Wire", "TestSupport"], swiftSettings: settings)'
IMPORT = "import PackageDescription\n"
KIT_TARGETS = "    targets: [\n        // Pure (Foundation only)."
APP_DEPENDENCY = '        .package(path: "../AbapitKit"),\n'
APP_MODELS_LAST = '.product(name: "History", package: kit), .product(name: "Assist", package: kit),\n        ], swiftSettings: settings),\n        .testTarget('
APP_TESTS_LAST = '.product(name: "JSONAPI", package: kit), .product(name: "HTTPCore", package: kit), .product(name: "TestSupport", package: kit),'


def swap(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"check_graph_selftest: a manifest changed, so a mutant no longer applies ({old[:60]!r} is there "
                         f"{text.count(old)} times): update this self-test with the manifest")
    return text.replace(old, new)


# (name, package, the change, every reason the check must print)
MUTANTS = [
    ("an edge computed in the manifest", KIT,
     lambda t: swap(t, ASSIST, ASSIST.replace('["Planners", "Reports"]', '["Planners", "Reports"] + ["ChangeCore"]')),
     ["Assist: declares"]),
    ("an edge appended after the package is made", KIT,
     lambda t: t + '\npackage.targets.first { $0.name == "Planners" }!.dependencies.append("HTTPCore")\n',
     ["Planners: declares"]),
    ("a package dependency", KIT,
     lambda t: swap(t, KIT_TARGETS, '    dependencies: [.package(path: "../AbapitApp")],\n' + KIT_TARGETS),
     ["package dependencies:"]),
    ("a test target that depends outside its module", KIT,
     lambda t: swap(t, WIRE_TESTS, WIRE_TESTS.replace('["Wire", "TestSupport"]', '["Wire", "TestSupport", "Vault"]')),
     ["WireTests: depends on ['Vault']"]),
    ("unsafeFlags in a target's settings", KIT,
     lambda t: swap(t, SETTINGS, SETTINGS.replace("\n]", '\n    .unsafeFlags(["-package-name", "abapitkit"]),\n]')),
     ["AbapitKit/Package.swift holds `unsafeFlags`", "Wire: unsafeFlags (they can name the package"]),
    ("a custom path", KIT,
     lambda t: swap(t, WIRE, '.target(name: "Wire", path: "Sources/Wire", swiftSettings: settings)'),
     ["Wire: custom path 'Sources/Wire'"]),
    ("an exclude", KIT,
     lambda t: swap(t, WIRE, '.target(name: "Wire", exclude: ["APIHost.swift"], swiftSettings: settings)'),
     ["Wire: exclude ['APIHost.swift']"]),
    ("an executable target", KIT,
     lambda t: swap(t, WIRE, WIRE + ',\n        .executableTarget(name: "Tool", swiftSettings: settings)'),
     ["Tool: a executable target"]),
    ("a second import", KIT,
     lambda t: swap(t, IMPORT, IMPORT + "import Foundation\n"),
     ["AbapitKit/Package.swift imports ['PackageDescription', 'Foundation']"]),
    ("a manifest that branches with #if", KIT,
     lambda t: swap(t, IMPORT, IMPORT + "#if os(Linux)\nlet onLinux = true\n#else\nlet onLinux = false\n#endif\n"),
     ["AbapitKit/Package.swift holds `#if`"]),
    ("a manifest that reads its environment", KIT,
     lambda t: swap(t, IMPORT, IMPORT + 'let sdk = Context.environment["SDKROOT"]\n'),
     ["AbapitKit/Package.swift holds `environment`", "AbapitKit/Package.swift holds `Context`"]),
    ("the screen models reach a module off their list", APP,
     lambda t: swap(t, APP_MODELS_LAST, '.product(name: "History", package: kit), .product(name: "Assist", package: kit),\n'
                    '            .product(name: "HTTPCore", package: kit),\n        ], swiftSettings: settings),\n        .testTarget('),
     ["AbapitApp: declares"]),
    ("the screen models' tests reach a module off their list", APP,
     lambda t: swap(t, APP_TESTS_LAST, APP_TESTS_LAST + '\n            .product(name: "ChangeCore", package: kit),'),
     ["AbapitApp AppModelsTests: depends on ['product:ChangeCore']"]),
    ("a second package dependency for the screen models", APP,
     lambda t: swap(t, APP_DEPENDENCY, APP_DEPENDENCY + '        .package(path: "../Other"),\n'),
     ["AbapitApp: dependencies"]),
    ("unsafeFlags in the screen models' settings", APP,
     lambda t: swap(t, SETTINGS, SETTINGS.replace("\n]", '\n    .unsafeFlags(["-package-name", "abapitkit"]),\n]')),
     ["AbapitApp/Package.swift holds `unsafeFlags`", "AppModels: unsafeFlags (they can name the package"]),
]


def run(tree: Path) -> tuple[int, str]:
    done = subprocess.run([sys.executable, "-I", str(tree / "scripts" / "check_graph.py")], capture_output=True, text=True)
    return done.returncode, done.stdout + done.stderr


def main() -> int:
    if not CHECK.is_file():
        raise SystemExit(f"check_graph_selftest: no check at {CHECK}")
    with tempfile.TemporaryDirectory() as scratch:
        tree = Path(scratch)
        (tree / "scripts").mkdir()
        shutil.copy(CHECK, tree / "scripts" / "check_graph.py")
        shutil.copytree(ROOT / "Packages", tree / "Packages", ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        status, output = run(tree)
        if status != 0:
            print(output, file=sys.stderr)
            raise SystemExit("check_graph_selftest: the unchanged copy does not pass the check")
        missed = []
        for name, package, change, reasons in MUTANTS:
            manifest = tree / "Packages" / package / "Package.swift"
            original = manifest.read_text()
            manifest.write_text(change(original))
            status, output = run(tree)
            manifest.write_text(original)
            absent = [reason for reason in reasons if reason not in output]
            if status != 1 or absent:
                missed.append(name)
                last = output.strip().splitlines()[-1] if output.strip() else ""
                print(f"NOT REFUSED AS EXPECTED: {name} (exit {status}; not printed: {absent}) :: {last[:200]}", file=sys.stderr)
            else:
                print(f"refused: {name}")
        status, output = run(tree)
        if status != 0:
            raise SystemExit("check_graph_selftest: the copy does not pass once every mutant is undone")
    if missed:
        print(f"check_graph_selftest: {len(missed)} of {len(MUTANTS)} mutants were not refused as expected", file=sys.stderr)
        return 1
    print(f"check_graph_selftest: ok ({len(MUTANTS)} mutant manifests refused, each for its own reason)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
