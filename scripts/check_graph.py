#!/usr/bin/env python3
"""Hold AbapitKit's dependency graph to the plan (plan §3.2), from the manifest SwiftPM itself evaluates.

`swift package dump-package` runs Package.swift and prints what it declares, so a dependency hidden in a
variable, a later `.append`, or behind a comment that repeats an old line is seen as SwiftPM sees it (Phase
0's review: the regex test missed all of those). This checks, exactly:

- every regular target's dependencies are the edges below, and nothing else; every test target depends
  only on the module it tests, its dependencies' modules and TestSupport;
- no package dependencies (L5), no binary, plugin, executable or macro targets, and no custom `path`,
  `sources` or `exclude` that could move code out of a module's own folder.

Imports are checked by the compiler: `scripts/test.sh` builds with
`--explicit-target-dependency-import-check error`, so a module can't import a package module it doesn't
declare. System frameworks are checked by `PackageGraphTests`.

    python3 -I scripts/check_graph.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages" / "AbapitKit"

# A new edge is a reviewed change to this list, PackageGraphTests' list and the plan.
EDGES = {
    "JSONAPI": set(),
    "AppleModels": {"JSONAPI"},
    "MosyleModels": set(),
    "Wire": set(),
    "Planners": {"AppleModels", "MosyleModels", "JSONAPI", "Wire"},
    "Reports": {"AppleModels", "MosyleModels"},
    "ProfileSchema": set(),
    "Vault": set(),
    "HTTPCore": {"Wire"},
    "AppleBusiness": {"HTTPCore", "Wire", "Vault", "AppleModels", "JSONAPI"},
    "Mosyle": {"HTTPCore", "Wire", "Vault", "MosyleModels"},
    "History": {"AppleModels", "MosyleModels", "Reports"},
    "ChangeCore": {"HTTPCore", "Wire", "Planners", "Vault"},
    "Assist": {"Planners", "Reports"},
    "TestSupport": {"HTTPCore", "Wire", "Vault", "AppleModels", "MosyleModels", "JSONAPI"},
}


def names(dependencies) -> set[str]:
    found = set()
    for dependency in dependencies:
        for kind in ("byName", "target", "product"):
            if kind in dependency:
                if kind == "product":
                    found.add(f"product:{dependency[kind][0]}")
                else:
                    found.add(dependency[kind][0])
    return found


def closure(module: str) -> set[str]:
    seen, stack = set(), [module]
    while stack:
        for edge in EDGES.get(stack.pop(), set()):
            if edge not in seen:
                seen.add(edge)
                stack.append(edge)
    return seen


def main() -> int:
    raw = subprocess.run(["swift", "package", "dump-package", "--package-path", str(PACKAGE)],
                         capture_output=True, check=True, text=True).stdout
    manifest = json.loads(raw)
    problems = []
    if manifest.get("dependencies"):
        problems.append(f"package dependencies: {manifest['dependencies']} (L5: none)")
    regular = {}
    for target in manifest["targets"]:
        name, kind = target["name"], target["type"]
        for key in ("path", "sources", "publicHeadersPath"):
            if target.get(key):
                problems.append(f"{name}: custom {key} {target[key]!r}")
        if target.get("exclude"):
            problems.append(f"{name}: exclude {target['exclude']!r}")
        if kind == "regular":
            regular[name] = names(target["dependencies"])
        elif kind == "test":
            tested = name.removesuffix("Tests")
            allowed = {"TestSupport"} | ({tested} | closure(tested) if tested in EDGES else set())
            if name == "SourceScanTests":
                allowed = {"TestSupport"}
            extra = names(target["dependencies"]) - allowed
            if extra:
                problems.append(f"{name}: depends on {sorted(extra)}, outside {tested} and its dependencies")
        else:
            problems.append(f"{name}: a {kind} target (only regular and test targets)")
    if regular != EDGES:
        for module in sorted(set(regular) | set(EDGES)):
            if regular.get(module) != EDGES.get(module):
                problems.append(f"{module}: declares {sorted(regular.get(module, set()))}, the plan allows {sorted(EDGES.get(module, set()))}")
    for problem in problems:
        print(f"check_graph: {problem}", file=sys.stderr)
    if not problems:
        print(f"check_graph: ok ({len(regular)} modules, {sum(len(v) for v in regular.values())} edges, no package dependencies)")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
