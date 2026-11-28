#!/usr/bin/env python3
"""Self-test of scripts/check_text.py: the text check must refuse a file holding any character below, and name it.

A check that was never seen to fail can't hold (RULE-FEEDBACK 2026-10-16, "a check that was never seen to fail").
Each case is a temporary git repository with one tracked file; the check runs there as CI's hygiene job runs it.
A case counts as refused only when the check exits 1 AND prints the file, the line and the code point. The
characters are written from their numbers, so this file holds none of them.

    python3 -I scripts/check_text_selftest.py
    CHECK_TEXT=path/to/another/check_text.py python3 scripts/check_text_selftest.py   (to see it fail on a weakened check)
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = Path(os.environ.get("CHECK_TEXT", ROOT / "scripts" / "check_text.py"))

# (what it is, code point): one for each clause of `invisible`, and both ends of two ranges.
REFUSED = [
    ("a bidirectional override (Cf; Trojan Source)", 0x202E),
    ("a zero-width space (Cf)", 0x200B),
    ("a format character outside the ignorable ranges (Cf)", 0x0600),
    ("a line separator (Zl)", 0x2028),
    ("a paragraph separator (Zp)", 0x2029),
    ("a no-break space (Zs)", 0x00A0),
    ("an ideographic space (Zs)", 0x3000),
    ("a control character (Cc)", 0x0007),
    ("a braille blank (the BLANKS set)", 0x2800),
    ("a Hangul filler (the IGNORABLE ranges; a letter, usable in an identifier)", 0x3164),
    ("a combining grapheme joiner (the IGNORABLE ranges; a mark)", 0x034F),
    ("a variation selector (the IGNORABLE ranges; a mark)", 0xFE0F),
    ("a Hangul choseong filler (the IGNORABLE ranges; a letter)", 0x115F),
]
# What the check must let through: ordinary text with a tab, CR LF and non-ASCII letters.
ALLOWED = "let name = " + chr(0x22) + "caf" + chr(0xE9) + chr(0x22) + chr(0x09) + "// " + chr(0x65E5) + chr(0x672C) + chr(0x0D) + chr(0x0A) + "done" + chr(0x0A)


def run(files: dict[str, bytes]) -> tuple[int, str]:
    """The check's exit status and output in a new repository holding `files`, all tracked."""
    with tempfile.TemporaryDirectory() as scratch:
        git = ["git", "-c", "core.autocrlf=false", "-c", "init.defaultBranch=main"]
        subprocess.run([*git, "init", "-q", scratch], check=True, capture_output=True)
        for name, data in files.items():
            path = Path(scratch) / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        subprocess.run([*git, "-C", scratch, "add", "-A"], check=True, capture_output=True)
        done = subprocess.run([sys.executable, "-I", str(CHECK)], cwd=scratch, capture_output=True, text=True)
        return done.returncode, done.stdout + done.stderr


def main() -> int:
    if not CHECK.is_file():
        raise SystemExit(f"check_text_selftest: no check at {CHECK}")
    status, output = run({"clean.swift": ALLOWED.encode()})
    if status != 0:
        print(output, file=sys.stderr)
        raise SystemExit("check_text_selftest: the check refuses ordinary text (a tab, CR LF, non-ASCII letters)")
    # The fuzzer's seed inputs are the one exemption: a seed separates its strings with NUL bytes.
    status, output = run({"Fuzz/corpus/seed": b"\x00A" + chr(0x202E).encode()})
    if status != 0:
        print(output, file=sys.stderr)
        raise SystemExit("check_text_selftest: the check refuses a fuzz seed input, which is exempt")
    missed = []
    for what, point in REFUSED:
        # On the second line, so the line number the check prints is checked too.
        status, output = run({"Sources/a.swift": ("let a = 1\nlet b = 2 " + chr(point) + "\n").encode()})
        wanted = f"Sources/a.swift:2: U+{point:04X}"
        if status != 1 or wanted not in output:
            missed.append(what)
            print(f"NOT REFUSED AS EXPECTED: {what}, U+{point:04X} (exit {status}; wanted {wanted!r})", file=sys.stderr)
        else:
            print(f"refused: U+{point:04X} {what}")
    # The exemption is the corpus folder only: the same bytes anywhere else are refused.
    status, output = run({"Fuzz/seed": b"A" + chr(0x202E).encode()})
    if status != 1 or "Fuzz/seed:1: U+202E" not in output:
        missed.append("outside Fuzz/corpus")
        print(f"NOT REFUSED AS EXPECTED: a bidirectional override in Fuzz/, outside Fuzz/corpus/ (exit {status})", file=sys.stderr)
    else:
        print("refused: U+202E outside Fuzz/corpus/")
    total = len(REFUSED) + 1
    if missed:
        print(f"check_text_selftest: {len(missed)} of {total} cases were not refused as expected", file=sys.stderr)
        return 1
    print(f"check_text_selftest: ok ({total} files refused, each naming its line and character; ordinary text and a seed input pass)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
