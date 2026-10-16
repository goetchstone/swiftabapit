#!/usr/bin/env bash
# Builds and runs the libFuzzer target Fuzz/AbapitFuzz.swift over the pure modules (plan §6.6). Linux
# only: Apple's toolchain ships no libFuzzer runtime. CI's `fuzz` job runs it in the pinned Swift image;
# on a Mac, the same through Docker:
#
#   docker run --rm -v "$PWD":/src -w /src swift:6.4@<digest in .github/workflows/ci.yml> \
#     scripts/fuzz.sh -seed=1 -runs=200000 -max_len=4096
#
# Arguments go to libFuzzer; pass a crash file to reproduce it. The pure modules' sources are compiled as
# one module with the fuzz entry point: their imports of each other are dropped in a scratch copy (so a
# type name must be unique across the pure modules — the same rule that keeps them unambiguous to read).
# Without a crash file the run starts from Fuzz/corpus (seed inputs, read only) and keeps what it finds in
# a scratch corpus, never the repo. Adapted from SwiftGamGui scripts/fuzz.sh @ bfdb494.
set -euo pipefail
cd "$(dirname "$0")/.."

pure="JSONAPI AppleModels MosyleModels Wire Planners Reports ProfileSchema"
out="${FUZZ_OUT:-${TMPDIR:-/tmp}/abapitfuzz}"
rm -rf "$out/src"
mkdir -p "$out/src" "$out/corpus"
pattern="$(printf '%s|' $pure | sed 's/|$//')"
for module in $pure; do
  for file in Packages/AbapitKit/Sources/"$module"/*.swift; do
    sed -E "/^(@testable )?import ($pattern)\$/d" "$file" > "$out/src/${module}_$(basename "$file")"
  done
done
swiftc -sanitize=fuzzer,address -parse-as-library -package-name abapitfuzz -module-name AbapitFuzz \
  Fuzz/AbapitFuzz.swift "$out"/src/*.swift -o "$out/abapitfuzz"
for arg in "$@"; do
  case "$arg" in -*) ;; *) exec "$out/abapitfuzz" -dict=Fuzz/abapit.dict "$@" ;; esac   # a crash file: reproduce it
done
exec "$out/abapitfuzz" -dict=Fuzz/abapit.dict "$@" "$out/corpus" Fuzz/corpus
