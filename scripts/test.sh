#!/usr/bin/env bash
# The package suite, the way CI runs it. Arguments go to `swift test` (e.g. --filter PlannersTests).
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --package-path Packages/AbapitKit "$@"
