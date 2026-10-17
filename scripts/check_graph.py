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
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages" / "AbapitKit"
# The screen models' package (Phase 1b review): outside AbapitKit as the app is, so they see its public API only. One
# dependency, AbapitKit by path; products only; no unsafeFlags, which could name AbapitKit's package and reopen it.
APP_PACKAGE = ROOT / "Packages" / "AbapitApp"
APP_EDGES = {"AppModels": {"product:AppleBusiness", "product:AppleModels", "product:Orgs", "product:Vault", "product:Reports"}}
APP_TESTS = {"AppModelsTests": {"AppModels", "product:JSONAPI", "product:HTTPCore", "product:TestSupport"} | APP_EDGES["AppModels"]}

# A new edge is a reviewed change to this list, PackageGraphTests' list and the plan.
EDGES = {
    "JSONAPI": set(),
    "AppleModels": {"JSONAPI"},
    "MosyleModels": set(),
    "Wire": set(),
    "Planners": {"AppleModels", "MosyleModels", "JSONAPI", "Wire"},
    "Reports": {"AppleModels", "MosyleModels", "JSONAPI"},
    "ProfileSchema": set(),
    "Orgs": {"JSONAPI"},
    "Vault": set(),
    "HTTPCore": {"Wire"},
    "AppleBusiness": {"HTTPCore", "Wire", "Vault", "Orgs", "AppleModels", "JSONAPI"},
    "Mosyle": {"HTTPCore", "Wire", "Vault", "Orgs", "MosyleModels"},
    "History": {"Orgs", "AppleModels", "MosyleModels", "Reports"},
    "ChangeCore": {"HTTPCore", "Wire", "Planners", "Vault", "Orgs"},
    "Assist": {"Planners", "Reports"},
    "TestSupport": {"HTTPCore", "Wire", "Vault", "Orgs", "AppleModels", "MosyleModels", "JSONAPI"},
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


def dump(package: Path) -> dict:
    raw = subprocess.run(["swift", "package", "dump-package", "--package-path", str(package)],
                         capture_output=True, check=True, text=True).stdout
    return json.loads(raw)


# What a manifest's code must not hold. A manifest is Swift run on the build machine and sees the environment: one
# that branched on SDKROOT (set when `swift` evaluates it, as here, and unset under xcodebuild) gave Xcode
# `-disable-access-control` while this check saw none (integration review H2). So a manifest imports
# PackageDescription alone and reads nothing about where it runs.
MANIFEST_REFUSED = ("unsafeFlags", "ProcessInfo", "environment", "Context", "getenv", "#if", "FileManager", "CommandLine",
                    "Process", "contentsOf", "dlopen")


def manifest_code(path: Path) -> str:
    """The manifest's code: block and line comments removed (no manifest here holds `//` in a string)."""
    text = re.sub(r"/\*.*?\*/", " ", path.read_text(), flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def check_manifest_text(path: Path, problems: list) -> None:
    code = manifest_code(path)
    imports = re.findall(r"^[ \t]*(?:@[A-Za-z_]+[ \t]+)*import[ \t]+([A-Za-z_][A-Za-z0-9_.]*)", code, flags=re.M)
    if imports != ["PackageDescription"]:
        problems.append(f"{path.parent.name}/Package.swift imports {imports} (PackageDescription only)")
    for word in MANIFEST_REFUSED:
        if word in code:
            problems.append(f"{path.parent.name}/Package.swift holds `{word}` (a manifest reads nothing about where it runs)")


def check_targets(manifest: dict, problems: list) -> None:
    """What every target of either package must not do: a custom path, an exclude, unsafeFlags, another kind."""
    for target in manifest["targets"]:
        name, kind = target["name"], target["type"]
        for key in ("path", "sources", "publicHeadersPath"):
            if target.get(key):
                problems.append(f"{name}: custom {key} {target[key]!r}")
        if target.get("exclude"):
            problems.append(f"{name}: exclude {target['exclude']!r}")
        for setting in target.get("settings", []):
            if "unsafeFlags" in json.dumps(setting.get("kind", {})):
                problems.append(f"{name}: unsafeFlags (they can name the package and open its `package` boundary)")
        if kind not in ("regular", "test"):
            problems.append(f"{name}: a {kind} target (only regular and test targets)")


def check_app_package(problems: list) -> int:
    """The screen models' package: AbapitKit by path and nothing else, its products only, the planned edges."""
    manifest = dump(APP_PACKAGE)
    dependencies = manifest.get("dependencies") or []
    paths = [Path(entry["path"]).resolve() for dependency in dependencies for entry in dependency.get("fileSystem", [])]
    if len(dependencies) != 1 or paths != [PACKAGE.resolve()]:
        problems.append(f"AbapitApp: dependencies {dependencies} (only AbapitKit, by path)")
    check_targets(manifest, problems)
    regular = {}
    for target in manifest["targets"]:
        found = names(target["dependencies"])
        if target["type"] == "regular":
            regular[target["name"]] = found
        elif target["type"] == "test":
            extra = found - APP_TESTS.get(target["name"], set())
            if extra:
                problems.append(f"AbapitApp {target['name']}: depends on {sorted(extra)}")
    if regular != APP_EDGES:
        problems.append(f"AbapitApp: declares {regular}, the plan allows {APP_EDGES}")
    return sum(len(v) for v in regular.values())


def main() -> int:
    manifest = dump(PACKAGE)
    problems = []
    for package in (PACKAGE, APP_PACKAGE):
        check_manifest_text(package / "Package.swift", problems)
    if manifest.get("dependencies"):
        problems.append(f"package dependencies: {manifest['dependencies']} (L5: none)")
    regular = {}
    check_targets(manifest, problems)
    for target in manifest["targets"]:
        name, kind = target["name"], target["type"]
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
    if regular != EDGES:
        for module in sorted(set(regular) | set(EDGES)):
            if regular.get(module) != EDGES.get(module):
                problems.append(f"{module}: declares {sorted(regular.get(module, set()))}, the plan allows {sorted(EDGES.get(module, set()))}")
    app_edges = check_app_package(problems)
    for problem in problems:
        print(f"check_graph: {problem}", file=sys.stderr)
    if not problems:
        print(f"check_graph: ok ({len(regular)} modules, {sum(len(v) for v in regular.values())} edges, no package dependencies; "
              f"AbapitApp: {len(APP_EDGES)} module, {app_edges} product edges, AbapitKit only)")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
