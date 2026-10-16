#!/usr/bin/env bash
# The package suite, the way CI runs it: the graph SwiftPM evaluates (scripts/check_graph.py), then a build in
# which a module importing a package module it doesn't declare is an error, then the tests. Arguments go to
# `swift test` (e.g. --filter PlannersTests).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I scripts/check_graph.py
exec swift test --package-path Packages/AbapitKit --explicit-target-dependency-import-check error "$@"
