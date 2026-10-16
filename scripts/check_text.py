#!/usr/bin/env python3
"""Refuse invisible and bidirectional-control characters in tracked text files.

They make code read differently from how it runs (Trojan Source, CVE-2021-42574), and an editing tool
can write one by decoding an escape a script meant to keep (RULE-FEEDBACK 2026-10-08). Write such
characters as escapes. Only the fuzzer's seed inputs are exempt (a seed input separates its strings with
NUL bytes); the generated goldens and contracts are written with JSON escapes, so they are checked too.
Adapted from SwiftGamGui scripts/check_text.py @ bfdb494.

    python3 scripts/check_text.py
"""

from __future__ import annotations

import subprocess
import sys
import unicodedata

EXEMPT: set[str] = set()
# Unicode's Default_Ignorable_Code_Point property (DerivedCoreProperties.txt), which unicodedata doesn't
# expose: characters rendered as nothing, such as the Hangul fillers (usable in identifiers), variation
# selectors and the combining grapheme joiner. Most are also format characters (Cf); not all.
IGNORABLE = ((0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160), (0x17B4, 0x17B5),
             (0x180B, 0x180F), (0x200B, 0x200F), (0x202A, 0x202E), (0x2060, 0x206F), (0x3164, 0x3164),
             (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF), (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3),
             (0x1D173, 0x1D17A), (0xE0000, 0xE0FFF))
BLANKS = {0x2800}  # BRAILLE PATTERN BLANK: a visible-width nothing that is a symbol, not a space


def invisible(char: str) -> bool:
    category, point = unicodedata.category(char), ord(char)
    return (category in ("Cf", "Zl", "Zp")                     # format controls (bidi, zero-width), separators
            or (category == "Zs" and char != " ")              # no-break and other spaces
            or (category == "Cc" and char not in "\t\n\r")     # control characters
            or point in BLANKS
            or any(low <= point <= high for low, high in IGNORABLE))


def main() -> int:
    paths = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.split(b"\0")
    found = 0
    for raw in paths:
        path = raw.decode()
        if not path or path in EXEMPT or path.startswith("Fuzz/corpus/"):
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue  # binary, a submodule, or deleted in the working tree
        for number, line in enumerate(text.split("\n"), 1):
            hits = sorted({f"U+{ord(c):04X}" for c in line if invisible(c)})
            if hits:
                print(f"{path}:{number}: {', '.join(hits)}")
                found += 1
    if found:
        print(f"{found} line(s) hold invisible or bidirectional characters; write them as escapes.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
