#!/usr/bin/env bash
# Both package suites, the way CI runs them: the graph SwiftPM evaluates (scripts/check_graph.py), then a build in
# which a module importing a package module it doesn't declare is an error, then the tests. Arguments go to
# `swift test` (e.g. --filter PlannersTests).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I scripts/check_graph.py
swift test --package-path Packages/AbapitKit --explicit-target-dependency-import-check error "$@"
# The screen models' own package, which sees AbapitKit's public API only (Phase 1b review). A --filter that names no
# test there still passes: swift test exits 0 when the filter leaves nothing to run.
exec swift test --package-path Packages/AbapitApp --explicit-target-dependency-import-check error "$@"
