#!/usr/bin/env python3
"""Generate the parity goldens in Tests/Fixtures/parity/ from frozen abapit (plan §6.2, invariant 6).

abapit (the Python app) is the behaviour reference. This script extracts abapit's package at the pinned
commit with `git archive` into a scratch directory, imports it from there (never from an installed
copy), runs each pure function over seeded generated inputs and hand-written edge cases, and writes what
it returned. Where abapit is wrong (plan §2.3), a case holds the CORRECTED expectation in `expected`
and abapit's own output in `abapit`; the Swift tests hold that deviation list narrow. Never edit a
golden by hand to make a test pass.

Corrections recorded here (the others in §2.3 are client behaviour, covered by the strict stubs):
  - serials: uppercase ASCII letters only (Python's str.upper() follows its Unicode version; a serial is
    ASCII, and a non-ASCII token matches no device either way);
  - csv: a dict or nested list cell is JSON (sorted keys), not Python's repr;
  - private keys: only P-256 is accepted (abapit accepts any key cryptography loads, then fails to sign);
  - mosyle adapt_device: an allowlist (defect 1, invariant 11): what abapit makes of the raw cut to the columns
    the list asks for, so no raw key is passed through (`activation_bypass*`, or a raw `serialNumber`); a serial
    that isn't a string gives the id its `str()` (abapit's id is the raw number or boolean; a Resource's id is a
    string);
  - mosyle adapt_user / adapt_group: cut to an allowlist (invariant 11; abapit kept every raw key, a password or a
    token included);
  - mosyle device dedupe: a list or an object serial is no key, so the device is kept (abapit raised TypeError and
    lost the whole list);
  - mosyle normalize_logs: a log entry that isn't an object is skipped (abapit raised AttributeError and lost the
    page; `abapit_without_junk` holds abapit's own reading once the junk is out);
  - mosyle compliance timestamps (`01:00 PM - 03/12/2024`, no zone) parse as local time (defect 5), with an hour
    of 1 to 12 and a proleptic Gregorian date.

Inputs come only from `random.Random(seed)` and literals here — no Hypothesis, so an unrelated edit to
this file can't move a drawn case (SwiftGamGui RULE-FEEDBACK 2026-10-08). Run it with abapit's venv
(it needs `cryptography` and `PyJWT`), isolated:

    ../abapit/.venv/bin/python -I -B scripts/gen_fixtures.py --abapit ../abapit
"""

from __future__ import annotations

import argparse
import atexit
import base64
import copy
import importlib
import io
import json
import math
import os
import platform
import random
import re
import shutil
import string
import struct
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

# abapit's main (the merge of PR #4). Its pure modules are identical to 9875ee7, which the plan was written
# at, but that commit lives only on an unmerged branch that may be deleted (Phase 0's review).
ABAPIT_PIN = "3890091ddc4e57372f45eb6b479ebf5fbcbbfa2f"
FIXED_NOW = datetime(2026, 10, 16, 12, 0, 0, tzinfo=timezone.utc)
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Tests" / "Fixtures" / "parity"

# Every code point Python's str.isspace() (and so `re`'s \s, and str.strip()) treats as whitespace.
PY_WHITESPACE = [c for c in range(0x110000) if chr(c).isspace()]


# -- loading abapit at the pin ---------------------------------------------------------------------

def load_abapit(repo: Path) -> dict:
    """abapit's modules, imported from a `git archive` of the pinned commit."""
    subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{ABAPIT_PIN}^{{commit}}"], check=True)
    archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", ABAPIT_PIN, "abapit"],
                             check=True, capture_output=True).stdout
    scratch = Path(tempfile.mkdtemp(prefix="abapit-pin-"))
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            if member.name.startswith("/") or ".." in Path(member.name).parts or not (member.isfile() or member.isdir()):
                raise SystemExit(f"unexpected archive member {member.name}")
        tar.extractall(scratch, filter="data")
    sys.path.insert(0, str(scratch))
    for name in list(sys.modules):
        if name == "abapit" or name.startswith("abapit."):
            del sys.modules[name]
    modules = {name: importlib.import_module(f"abapit.{name}")
               for name in ("assign", "blueprint_plan", "reports", "history", "config", "auth", "mosyle")}
    for module in modules.values():
        if not str(Path(module.__file__).resolve()).startswith(str(scratch.resolve())):
            raise SystemExit(f"{module.__name__} came from {module.__file__}, not the pinned archive")
    os.environ["ABAPIT_DATA_DIR"] = str(scratch / "data")
    os.environ["ABAPIT_CONFIG_DIR"] = str(scratch / "config")
    modules["scratch"] = scratch
    atexit.register(shutil.rmtree, scratch, ignore_errors=True)   # the throwaway keys written below go with it
    return modules


def header(seed: int | None) -> dict:
    return {"generator": "scripts/gen_fixtures.py", "abapit": ABAPIT_PIN, "python": platform.python_version(),
            "unicode": unicodedata.unidata_version, "seed": seed, "now": FIXED_NOW.isoformat()}


def write(name: str, payload: dict) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    # Insertion order, never sorted: abapit's CSV columns are its attributes' first-seen order, so an input's
    # key order is part of the case. The generation is seeded, so the order is as deterministic as the values.
    text = json.dumps(payload, indent=1, ensure_ascii=True, default=str) + "\n"
    (OUT / f"{name}.json").write_text(text)
    print(f"{name}: {len(payload.get('cases', []))} cases", file=sys.stderr)


def jsonable(value):
    """abapit's outputs as JSON: tuples become lists, Counters and sets are already lists by now."""
    return json.loads(json.dumps(value, default=str))


def outcome(call):
    try:
        return {"ok": jsonable(call())}
    except Exception as error:  # noqa: BLE001 — the golden records abapit's refusal, whatever it is
        return {"error": type(error).__name__, "message": str(error)}


# -- shared generated data -------------------------------------------------------------------------

FAMILIES = ["Mac", "iPhone", "iPad", "AppleTV", "Watch", "Vision"]
MODELS = {"Mac": ["MacBook Air 13-inch (M3)", "Mac mini (M4)"], "iPhone": ["iPhone 16", "iPhone 15"],
          "iPad": ["iPad Air 11-inch (M2)"], "AppleTV": ["Apple TV 4K (3rd gen)"], "Watch": ["Apple Watch Series 10"],
          "Vision": ["Apple Vision Pro"]}


def fake_serial(rng: random.Random) -> str:
    """Obviously fake: TEST and eight letters or digits (tenant data never enters the repo)."""
    return "TEST" + "".join(rng.choices(string.ascii_uppercase + string.digits, k=8))


def iso(dt: datetime, style: int) -> str:
    if style == 0:
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    if style == 1:
        return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"
    if style == 2:
        return dt.isoformat()
    return dt.strftime("%Y-%m-%d")


def when(rng: random.Random, days_back: int = 2000, days_ahead: int = 0) -> str | None:
    roll = rng.random()
    if roll < 0.06:
        return None
    if roll < 0.08:
        return ""
    if roll < 0.09:
        return "not a date"
    offset = rng.uniform(-days_back, days_ahead)
    dt = FIXED_NOW + timedelta(days=offset, seconds=rng.randint(0, 86399))
    return iso(dt.replace(microsecond=rng.randint(0, 999) * 1000), rng.choice([0, 0, 0, 1, 2, 3]))


def device(rng: random.Random, serial: str | None = None) -> dict:
    family = rng.choice(FAMILIES)
    attrs = {"serialNumber": serial, "productFamily": family, "deviceModel": rng.choice(MODELS[family]),
             "status": rng.choice(["ASSIGNED", "UNASSIGNED"]), "addedToOrgDateTime": when(rng),
             "orderDateTime": when(rng, 2600)}
    for key in list(attrs):
        if attrs[key] is None and rng.random() < 0.5:
            del attrs[key]
    if rng.random() < 0.05:
        attrs["productFamily"] = ""
    sid = serial or fake_serial(rng)
    attrs["serialNumber"] = sid
    return {"type": "orgDevices", "id": sid, "attributes": attrs}


def fleet(rng: random.Random, low: int = 0, high: int = 30) -> list[dict]:
    return [device(rng) for _ in range(rng.randint(low, high))]


def servers(rng: random.Random, count: int) -> list[dict]:
    names = ["Mosyle", "Jamf Pro", "Kandji", "Apple Configurator", "Intune"]
    return [{"type": "mdmServers", "id": f"{0xA0 + i:02X}" + "".join(rng.choices("0123456789ABCDEF", k=30)),
             "attributes": {"serverName": names[i % len(names)], "serverType": "MDM"}} for i in range(count)]


def applecare(rng: random.Random, devices: list[dict]) -> list[dict]:
    rows = []
    for d in devices:
        for _ in range(rng.choice([0, 1, 1, 2])):
            rows.append({"type": "applecare", "id": f"{d['id']}:{rng.randint(0, 9)}", "attributes": {
                "serialNumber": d["id"], "status": rng.choice(["ACTIVE", "ACTIVE", "INACTIVE"]),
                "description": rng.choice(["Limited Warranty", "AppleCare+", "AppleCare for Enterprise"]),
                "endDateTime": when(rng, 400, 400), "startDateTime": when(rng, 900)}})
    return rows


# -- serials ---------------------------------------------------------------------------------------

def corrected_serials(raw: str) -> list[str]:
    """The Swift parser's spec: split on runs of Python whitespace, ',' and ';'; uppercase ASCII a-z
    only; drop empties; dedupe keeping the first."""
    seen, out = set(), []
    for token in re.split(r"[\s,;]+", raw.strip()):
        token = "".join(c.upper() if "a" <= c <= "z" else c for c in token.strip())
        if token and token not in seen:
            seen.add(token)
            out.append(token)
    return out


def gen_serials(m: dict) -> None:
    rng = random.Random(1001)
    literal = ["", "   ", "c02x", "a,b;c d", "A a", "c02x,  C02X", "\tx\ny\r\n", "x,,;;y", "a\u00a0b", "a\u2003b",
               "a\u001cb", "a\u200bb", "ab\u0085cd", "a\u3000b", "é", "straße", "ǆx", "ıd",
               "  lead and trail  ", "dup dup DUP", "x;y,z w\nv", "a\fb\vc", "SERIAL-1 serial-1", "\ufeffab"]
    seps = [" ", ",", ";", "\t", "\n", "\r\n", ", ", "\u00a0", "\u2028", "\x1c", "\x0b", "\x0c", "  ;  "]
    alphabet = string.ascii_letters + string.digits + "-_."
    extra = ["é", "ß", "ı", "ñ", "ǆ", "և"]
    cases = []
    for raw in literal + [None] * 220:
        if raw is None:
            tokens = []
            for _ in range(rng.randint(0, 12)):
                token = "".join(rng.choices(alphabet, k=rng.randint(1, 14)))
                if rng.random() < 0.01:
                    token += rng.choice(extra)
                if tokens and rng.random() < 0.15:
                    token = rng.choice(tokens).swapcase()
                tokens.append(token)
            raw = "".join(t + rng.choice(seps) for t in tokens)
            if rng.random() < 0.3:
                raw = rng.choice(seps) + raw
        abapit = m["assign"].parse_serials(raw)
        expected = corrected_serials(raw)
        case = {"input": raw, "expected": expected}
        if abapit != expected:
            case["abapit"] = abapit
        cases.append(case)
    write("serials", {**header(1001), "python_whitespace": PY_WHITESPACE, "cases": cases})


# -- assignment plans ------------------------------------------------------------------------------

def gen_assign(m: dict) -> None:
    rng = random.Random(1002)
    cases = []
    for index in range(90):
        devices = fleet(rng, 1, 25)
        if rng.random() < 0.2:
            devices[0]["id"] = devices[0]["id"].lower()
        svcs = servers(rng, rng.randint(1, 3))
        mapping = {s["id"]: [] for s in svcs}
        for d in devices:
            if rng.random() < 0.6:
                mapping[rng.choice(svcs)["id"]].append(d["id"] if rng.random() < 0.8 else d["id"].lower())
        requested = [rng.choice(devices)["id"] for _ in range(rng.randint(0, 8))]
        requested += [fake_serial(rng) for _ in range(rng.randint(0, 2))]
        requested = [s.lower() if rng.random() < 0.3 else s for s in requested]
        raw = rng.choice([" ", ",", "\n", "; "]).join(requested)
        action = rng.choice(["assign", "unassign"] + (["move"] if index % 30 == 0 else []))
        server_id = rng.choice(svcs)["id"] if index % 25 else "unknown-service"
        call = lambda: m["assign"].plan(raw, action, server_id, copy.deepcopy(devices), svcs, mapping)  # noqa: E731
        cases.append({"input": {"raw": raw, "action": action, "server_id": server_id, "devices": devices,
                                "servers": svcs, "server_device_ids": mapping}, "expected": outcome(call)})
    write("assign_plan", {**header(1002), "cases": cases})


def gen_blueprint_relationships(m: dict) -> None:
    rng = random.Random(1003)
    cases = []
    for index in range(60):
        catalog = {f"id-{i}": f"Item {i}" for i in rng.sample(range(40), rng.randint(0, 12))}
        current = rng.sample(sorted(catalog), rng.randint(0, len(catalog))) if catalog else []
        selected = [rng.choice(sorted(catalog)) for _ in range(rng.randint(0, 6))] if catalog else []
        selected += [f"id-{rng.randint(40, 50)}" for _ in range(rng.randint(0, 2))]
        if rng.random() < 0.2:
            selected.append("")
        op = rng.choice(["add", "remove"] + (["replace"] if index % 20 == 0 else []))
        call = lambda: m["blueprint_plan"].plan_relationship(op, selected, current, catalog)  # noqa: E731
        cases.append({"input": {"op": op, "selected_ids": selected, "current_ids": current, "catalog": catalog},
                      "expected": outcome(call)})
    write("blueprint_relationship", {**header(1003), "cases": cases})


# -- reports ---------------------------------------------------------------------------------------

class FrozenDatetime(datetime):
    @classmethod
    def now(cls, tz=None):
        return FIXED_NOW if tz is not None else FIXED_NOW.replace(tzinfo=None)


def mosyle_like(rng: random.Random, serial: str | None = None) -> dict:
    family = rng.choice(["Mac", "iPhone", "iPad", "AppleTV"])
    attrs = {"productFamily": family, "deviceModel": rng.choice(MODELS[family]),
             "osVersion": rng.choice(["26.0", "26.0.1", "27.0", "18.6", "", None]),
             "lastCheckIn": when(rng, 120), "currentUser": rng.choice(["", "avery@example.com", "kai@example.com"]),
             "status": rng.choice(["enrolled", "pending", ""]), "enrolledAt": when(rng, 900),
             "lastMdmCheckIn": when(rng, 60), "lastPush": when(rng, 30)}
    sid = serial or fake_serial(rng)
    if rng.random() < 0.2:
        sid = sid.lower()
    return {"type": "orgDevices", "id": sid, "attributes": {k: v for k, v in attrs.items() if v is not None}}


AUDIT_TYPES = ["SUBSCRIPTION_CREATED", "SUBSCRIPTION_UPDATED", "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED",
               "DEVICE_ADDED_TO_ORG", "DEVICE_ASSIGNED_TO_SERVER", "DEVICE_UNASSIGNED_FROM_SERVER",
               "DEVICE_IS_ERASED", "ACCOUNT_PASSWORD_CHANGED", "ROLE_CREATED", "API_ACCOUNT_KEY_REVOKED"]


def audit_events(rng: random.Random, count: int) -> list[dict]:
    events = []
    for i in range(count):
        attrs = {"type": rng.choice(AUDIT_TYPES), "eventDateTime": when(rng, 60),
                 "outcome": rng.choice(["SUCCESS", "FAILURE", ""])}
        events.append({"type": "auditEvents", "id": f"evt-{i}", "attributes": attrs})
    return events


def gen_reports(m: dict) -> None:
    reports = m["reports"]
    reports.datetime = FrozenDatetime  # device_stats reads datetime.now() itself
    rng = random.Random(1004)
    cases = []

    def add(function, args, call):
        cases.append({"function": function, "input": args, "expected": outcome(call)})

    for _ in range(25):
        devices = fleet(rng, 0, 40)
        add("device_stats", {"devices": devices}, lambda: reports.device_stats(devices))
    for _ in range(20):
        devices = fleet(rng, 0, 20)
        svcs = servers(rng, rng.randint(0, 3))
        mapping = {s["id"]: [d["id"] for d in devices if rng.random() < 0.4] + ([fake_serial(rng)] if rng.random() < 0.3 else [])
                   for s in svcs}
        add("assignment_summary", {"devices": devices, "servers": svcs, "server_device_ids": mapping},
            lambda: reports.assignment_summary(devices, svcs, mapping))
    for _ in range(20):
        devices = fleet(rng, 0, 20)
        care = applecare(rng, devices) + applecare(rng, fleet(rng, 0, 3))
        days = rng.choice([0, 30, 90, 365])
        add("coverage_report", {"applecare_items": care, "devices": devices, "days": days},
            lambda: reports.coverage_report(care, devices, days, now=FIXED_NOW))
    for _ in range(20):
        devices = fleet(rng, 0, 25)
        care = applecare(rng, devices) if rng.random() < 0.7 else None
        years = rng.choice([1, 3, 4, 5])
        add("fleet_age_report", {"devices": devices, "applecare_items": care, "years": years},
            lambda: reports.fleet_age_report(devices, care, years, now=FIXED_NOW))
    for _ in range(15):
        events = audit_events(rng, rng.randint(0, 30))
        which = rng.choice(["SUBSCRIPTION_EVENTS", "DEVICE_LIFECYCLE_EVENTS"])
        add("audit_digest", {"events": events, "types": which},
            lambda: reports.audit_digest(events, getattr(reports, which)))
    for _ in range(20):
        shared = [fake_serial(rng) for _ in range(rng.randint(0, 10))]
        abm = [device(rng, s) for s in shared if rng.random() < 0.8] + fleet(rng, 0, 6)
        mosyle = [mosyle_like(rng, s) for s in shared if rng.random() < 0.8] + [mosyle_like(rng) for _ in range(rng.randint(0, 6))]
        if rng.random() < 0.2:
            abm.append({"type": "orgDevices", "id": "", "attributes": {}})
        add("reconcile_enrollments", {"abm_devices": abm, "mosyle_devices": mosyle},
            lambda: reports.reconcile_enrollments(abm, mosyle))
    for _ in range(20):
        abm = device(rng)["attributes"] if rng.random() < 0.8 else None
        mosyle = mosyle_like(rng)["attributes"] if rng.random() < 0.8 else None
        events = audit_events(rng, rng.randint(0, 5)) if rng.random() < 0.7 else None
        add("device_timeline", {"abm_attrs": abm, "mosyle_attrs": mosyle, "audit_events": events},
            lambda: reports.device_timeline(abm, mosyle, events))
    for _ in range(15):
        devices = [mosyle_like(rng) for _ in range(rng.randint(0, 30))]
        add("mosyle_os_breakdown", {"devices": devices}, lambda: reports.mosyle_os_breakdown(devices))
    for _ in range(15):
        devices = [mosyle_like(rng) for _ in range(rng.randint(0, 25))]
        days = rng.choice([0, 7, 30, 90])
        add("mosyle_stale_devices", {"devices": devices, "days": days},
            lambda: reports.mosyle_stale_devices(devices, days, now=FIXED_NOW))
    for value in ["2024-03-01T10:00:00Z", "2024-03-01T10:00:00.123Z", "2024-03-01T10:00:00+00:00",
                  "2024-03-01T10:00:00.123456+02:00", "2024-03-01", "2024-03-01T10:00", "2024-03-01 10:00:00",
                  "20240301", "2024-03-01T10:00:00", "2024-13-01", "", None, "not a date", "2024-03-01T10:00:00ZZ",
                  "2024-03-01T24:00:00Z", "2024-W09", "2024-03-01T10:00:00.5Z", "  2024-03-01  ",
                  "2024-03-01T10:00:00,5Z", "2024-03-01T10", "2024-03-01T1000", "2024-03-01T10:00:00.1234567Z",
                  "2024-03-01T10:00:00+0530", "2024-03-01T10:00:00+05", "2024-03-01T10:00:00-00:00", "2024-03",
                  "2024-03-01T10:00:00 +00:00", "2024-02-29", "2023-02-29", "2024-03-01T10:00:60Z",
                  "2024-03-01T10:00:00+24:00", "2024-03-01T23:59:59.999999-12:00", "0001-01-01", "9999-12-31T23:59:59Z"]:
        parsed = reports.parse_iso(value)
        abapit = parsed.isoformat() if parsed else None
        # Python 3.11+ reads ISO week dates and a space before the offset; neither appears in Apple's or
        # Mosyle's data, and the Swift parser refuses both (a listed deviation).
        corrected = None if isinstance(value, str) and ("W" in value or " +" in value) else abapit
        case = {"function": "parse_iso", "input": {"value": value}, "expected": {"ok": corrected}}
        if corrected != abapit:
            case["abapit"] = {"ok": abapit}
        cases.append(case)
    for _ in range(10):
        attrs = rng.choice([{"deviceModel": "iPhone 16"}, {"name": "Sales"}, {"serverName": "Mosyle", "name": ""},
                            {"managedAppleAccount": "avery@example.com"}, {"description": "AppleCare+"}, {},
                            {"deviceModel": "", "name": None, "description": 0}, {"name": 5}])
        cases.append({"function": "item_label", "input": {"attributes": attrs},
                      "expected": {"ok": m["history"].item_label(attrs)}})
    write("reports", {**header(1004), "cases": cases})


# -- CSV -------------------------------------------------------------------------------------------

def corrected_cell(value) -> str:
    """abapit's _cell, with JSON for containers instead of Python's repr."""
    if value is None:
        return ""
    if isinstance(value, dict):
        return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "; ".join(corrected_cell(v) if isinstance(v, (dict, list)) else str(v) for v in value)
    return str(value)


def corrected_csv(m: dict, items: list[dict]) -> str:
    reports = m["reports"]
    columns: list[str] = []
    for item in items:
        for key in item.get("attributes", {}):
            if key not in columns:
                columns.append(key)
    rows = [["id"] + columns] + [[item.get("id", "")] + [corrected_cell(item.get("attributes", {}).get(c)) for c in columns]
                                 for item in items]
    import csv as pycsv
    buffer = io.StringIO()
    writer = pycsv.writer(buffer)
    writer.writerows([[reports._csv_safe(cell) for cell in row] for row in rows])
    return buffer.getvalue()


def gen_csv(m: dict) -> None:
    rng = random.Random(1005)
    risky = ["=SUM(A1)", "+1", "-1", "@cmd", "\tx", "\rx", "a,b", 'say "hi"', "line\nbreak", "cr\rlf", " lead", "trail ",
             "", "été", "日本", "'quoted", "=", "plain"]
    scalars = [None, True, False, 0, 5, -3, 0.81, 64.0, 1e-05, 1e16, 2.5]
    cases = []
    for _ in range(70):
        items = []
        keys = rng.sample(["serialNumber", "deviceModel", "=formula", "status", "tags", "notes", "meta", "count",
                           "ratio", "name", "@at"], rng.randint(0, 6))
        for i in range(rng.randint(0, 6)):
            attrs = {}
            for key in keys:
                if rng.random() < 0.15:
                    continue
                roll = rng.random()
                if roll < 0.45:
                    attrs[key] = rng.choice(risky)
                elif roll < 0.7:
                    attrs[key] = rng.choice(scalars)
                elif roll < 0.85:
                    attrs[key] = [rng.choice(risky + ["x", "y"]) for _ in range(rng.randint(0, 3))]
                elif roll < 0.93:
                    attrs[key] = {"b": rng.choice(risky), "a": rng.choice(scalars)}
                else:
                    attrs[key] = [{"id": "x", "n": 1}, "y"]
            items.append({"type": "orgDevices", "id": rng.choice(["", "TEST1", "=id", f"TEST{i}"]), "attributes": attrs})
        abapit = m["reports"].items_to_csv(items)
        expected = corrected_csv(m, items)
        case = {"input": items, "expected": expected}
        if abapit != expected:
            case["abapit"] = abapit
        cases.append(case)
    write("csv", {**header(1005), "cases": cases})


# -- snapshot diffs --------------------------------------------------------------------------------

def gen_diff(m: dict) -> None:
    history = m["history"]
    rng = random.Random(1006)
    cases = []
    conn = history.connect()
    for _ in range(40):
        def snapshot_data():
            data = {}
            for resource in rng.sample(["devices", "mdm_servers", "assignments", "applecare", "users"], rng.randint(0, 4)):
                data[resource] = {}
                for i in rng.sample(range(12), rng.randint(0, 8)):
                    data[resource][f"id-{i}"] = {"name": rng.choice(["A", "B", "C"]), "count": rng.choice([1, 2, None]),
                                                 "tags": rng.choice([["x"], ["x", "y"], []])}
                    if rng.random() < 0.3:
                        data[resource][f"id-{i}"]["extra"] = rng.choice(["e", 1.5, False])
            return data
        old = snapshot_data()
        new = copy.deepcopy(old) if rng.random() < 0.5 else snapshot_data()
        for resource in new:
            for key in list(new[resource]):
                if rng.random() < 0.2:
                    new[resource][key]["name"] = rng.choice(["A", "B", "Z"])
                if rng.random() < 0.1:
                    del new[resource][key]
        ids = []
        with conn:
            for data in (old, new):
                cur = conn.execute("INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors) "
                                   "VALUES ('2026-10-16T12:00:00Z', 'gen', 'Gen', 'business', '0.2.0', '{}')")
                ids.append(cur.lastrowid)
                for resource, items in data.items():
                    conn.executemany("INSERT INTO items VALUES (?, ?, ?, ?)",
                                     [(cur.lastrowid, resource, key, json.dumps(attrs, sort_keys=True)) for key, attrs in items.items()])
        cases.append({"input": {"old": old, "new": new}, "expected": outcome(lambda: history.diff_snapshots(ids[0], ids[1]))})
    conn.close()
    write("diff", {**header(1006), "cases": cases})


# -- private keys and the client assertion ---------------------------------------------------------

def gen_keys_and_claims(m: dict) -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    import jwt

    def pem(key, fmt) -> str:
        return key.private_bytes(serialization.Encoding.PEM, fmt, serialization.NoEncryption()).decode()

    sec1, pkcs8 = serialization.PrivateFormat.TraditionalOpenSSL, serialization.PrivateFormat.PKCS8
    # Throwaway keys from fixed scalars: deterministic, and never used for anything real.
    keys = [ec.derive_private_key(scalar, ec.SECP256R1()) for scalar in (0x1111, 0xC0FFEE * 0x10001, 2**255 - 19)]
    p384 = ec.derive_private_key(0x2222, ec.SECP384R1())

    def swap(text: str) -> str:
        if "BEGIN EC PRIVATE KEY" in text:
            return text.replace("BEGIN EC PRIVATE KEY", "BEGIN PRIVATE KEY").replace("END EC PRIVATE KEY", "END PRIVATE KEY")
        return text.replace("BEGIN PRIVATE KEY", "BEGIN EC PRIVATE KEY").replace("END PRIVATE KEY", "END EC PRIVATE KEY")

    inputs = []
    for key in keys:
        scalar = f"{key.private_numbers().private_value:064x}"
        for name, text in [("sec1", pem(key, sec1)), ("pkcs8", pem(key, pkcs8))]:
            inputs += [(f"{name}", text, scalar), (f"{name}-crlf", text.replace("\n", "\r\n"), scalar),
                       (f"{name}-cr", text.replace("\n", "\r"), scalar), (f"{name}-mislabelled", swap(text), scalar),
                       (f"{name}-padded", "\n\n  " + text.strip() + "  \n\n", scalar),
                       (f"{name}-no-newline", text.strip(), scalar)]
    # No RSA or real encrypted key: their generation is random, and a golden must not move between runs.
    inputs += [("p384", pem(p384, pkcs8), None), ("p384-sec1", pem(p384, sec1), None), ("empty", "", None),
               ("garbage", "-----BEGIN PRIVATE KEY-----\nnot base64\n-----END PRIVATE KEY-----\n", None),
               ("public", keys[0].public_key().public_bytes(serialization.Encoding.PEM,
                                                            serialization.PublicFormat.SubjectPublicKeyInfo).decode(), None),
               ("truncated", pem(keys[0], pkcs8)[:120] + "\n-----END PRIVATE KEY-----\n", None),
               ("encrypted-label", "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIGHAgEAMBMG\n-----END ENCRYPTED PRIVATE KEY-----\n", None)]
    cases = []
    for name, text, scalar in inputs:
        result = outcome(lambda: m["config"].normalize_private_key(text))
        accepted = "ok" in result
        expected = {"accepted": scalar is not None, "scalar": scalar}
        case = {"name": name, "input": text, "expected": expected}
        if accepted:
            case["normalized"] = result["ok"]   # abapit's canonical PKCS#8 PEM, for reference
        if accepted != expected["accepted"]:
            case["abapit"] = {"accepted": accepted}
        cases.append(case)
    write("private_keys", {**header(None), "cases": cases})

    claims = []
    scratch = m["scratch"]
    for index, (client_id, key_id, team_id) in enumerate([
            ("BUSINESSAPI.00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-0000000000aa", ""),
            ("SCHOOLAPI.00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-0000000000bb", "TEAM000001")]):
        key_path = scratch / f"claims-{index}.pem"
        key_path.write_text(pem(keys[index], pkcs8))
        org = m["config"].Org(name="Example", scope=["business", "school"][index], client_id=client_id, key_id=key_id,
                              private_key_path=str(key_path), team_id=team_id)
        token = m["auth"].build_client_assertion(org, now=1_790_000_000)
        payload = jwt.decode(token, options={"verify_signature": False})
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", payload.pop("jti")):
            raise SystemExit("jti is not a UUID4")
        signature = base64.urlsafe_b64decode(token.split(".")[2] + "==")
        claims.append({"input": {"client_id": client_id, "key_id": key_id, "team_id": team_id, "scope": org.scope,
                                 "now": 1_790_000_000},
                       "expected": {"header": jwt.get_unverified_header(token), "payload": payload,
                                    "jti": "uuid4", "signature_bytes": len(signature),
                                    "token_scope": m["auth"].SCOPES[org.scope], "token_url": m["auth"].TOKEN_URL}})
    write("auth_claims", {**header(None), "cases": claims})


# -- Mosyle adapters -------------------------------------------------------------------------------

# Defect 5's parser. abapit left the stamp unparsed, so this is the spec rather than abapit's behaviour: the whole
# string (`fullmatch`: `$` also matches before a final newline), ASCII digits only (`\d` alone takes any script's),
# an hour of 1 to 12 (Phase 7a review L4: `13:00 PM` and `00:30 PM` read as times), and a real date in the
# proleptic Gregorian calendar Python's datetime keeps (`02/29/1500` is not one).
COMPLIANCE = re.compile(r"(\d{1,2}):(\d{2}) (AM|PM) - (\d{2})/(\d{2})/(\d{4})", re.ASCII)


def compliance_time(value) -> str | None:
    """Defect 5: Mosyle's compliance timestamp, no zone given, read as local time (no suffix)."""
    match = COMPLIANCE.fullmatch(value) if isinstance(value, str) else None
    if not match:
        return None
    hour, minute, half, month, day, year = (int(part) if part.isdigit() else part for part in match.groups())
    if not 1 <= hour <= 12:
        return None
    try:
        stamp = datetime(year, month, day, hour % 12 + (12 if half == "PM" else 0), minute)
    except ValueError:
        return None
    return f"{stamp.year:04d}-{stamp.month:02d}-{stamp.day:02d}T{stamp.hour:02d}:{stamp.minute:02d}:00"


# Phase 7a review L1 (invariant 11): users and groups pass an allowlist, as devices do. abapit's adapt_user and
# adapt_group kept every raw key (its generic tables and its CSV showed them all), so a password or a bypass code
# sent on a user reached the page and the export. Kept: abapit's own names and the raw fields they read, the only
# Mosyle user and group fields with a source here. MosyleAdapter.userAttributes and groupAttributes equal these
# (the "allowlists" case pins them).
USER_ATTRIBUTES = ["name", "email", "identifier", "userType", "iduser", "id", "managedappleid", "type", "usertype"]
GROUP_ATTRIBUTES = ["name", "identifier", "memberCount", "os", "idusergroup", "iddevicegroup", "id", "device_numbers",
                    "idusers_primary", "members"]


def allowlisted(case: dict, abapit: dict, allowed: list) -> dict:
    """The case with abapit's item cut to `allowed` as `expected`, and abapit's own beside it when they differ."""
    expected = copy.deepcopy(abapit)
    expected["attributes"] = {k: v for k, v in expected["attributes"].items() if k in allowed}
    case["expected"] = expected
    if expected != abapit:
        case["abapit"] = abapit
    return case


def sensitive_extras(rng: random.Random) -> dict:
    """What must not get past the user and group allowlist: a bypass code, a password, tokens, an unknown field."""
    keys = {"activation_bypass": "TESTBYPASS-" + "".join(rng.choices(string.ascii_uppercase, k=8)),
            "password": "TESTPASSWORD", "token": "TESTTOKEN", "apikey": "TESTAPIKEY", "custom_field": "x"}
    return {k: v for k, v in keys.items() if rng.random() < 0.3}


def json_case(function: str, text: str, call) -> dict:
    """A case whose input is the JSON text Mosyle would send (`input_json`). Swift parses it as abapit's httpx
    did, so a number reaches the code as written (`1e20`), not as Python writes it back (`1e+20`)."""
    return {"function": function, "input_json": text, "expected": jsonable(call(json.loads(text)))}


def logs_without_junk(block):
    """The response with each `Logs` that isn't a list emptied and each of its entries that isn't an object taken
    out: the corrected reading. abapit called `.get` on them and raised AttributeError, losing the whole page.
    Only the containers are walked, never a log entry itself."""
    if not isinstance(block, dict):
        return block
    return {key: ([entry for entry in value if isinstance(entry, dict)] if isinstance(value, list) else []) if key == "Logs"
            else logs_without_junk(value) for key, value in block.items()}


def logs_case(mosyle, response: dict, text: str | None = None) -> dict:
    """normalize_logs, with defect 5's correction: compliance stamps parsed, then newest first again."""
    try:
        abapit = jsonable(mosyle.normalize_logs(response))
    except AttributeError:
        abapit = "AttributeError"
    expected = jsonable(mosyle.normalize_logs(logs_without_junk(response)))
    if abapit != "AttributeError" and expected != abapit:
        raise SystemExit(f"taking out the junk changed a log abapit read: {response}")
    for event in expected:
        if event["kind"] == "compliance":
            event["when"] = compliance_time(event["when"]) or event["when"]
    expected.sort(key=lambda e: e["when"], reverse=True)
    case = {"function": "normalize_logs", **({"input_json": text} if text else {"input": response}), "expected": expected}
    if expected != abapit:
        case["abapit"] = abapit
    if abapit == "AttributeError":
        # Verifier round 1: what abapit made of the response once the junk was out, so the test can check that the
        # expectation differs from it only by the compliance stamps.
        case["abapit_without_junk"] = jsonable(mosyle.normalize_logs(logs_without_junk(response)))
    return case


def corrected_device_key(raw: dict):
    """abapit's dedupe key, `raw.get("serial_number") or raw.get("deviceudid")`, except that a list or an object is
    no key: abapit raised TypeError on one (unhashable) and lost the whole device list; here that device is kept."""
    key = raw.get("serial_number") or raw.get("deviceudid")
    return None if isinstance(key, (list, dict)) else key


def dedupe_case(m: dict, text: str) -> dict:
    """abapit's own MosyleClient.devices() over one page of devices (JSON text, parsed as httpx parses it), with
    `_post` answering in place of the network: which rows survive its dedupe, by their `custom_index`."""
    client = m["mosyle"].MosyleClient(m["config"].Org(name="parity", scope="business", client_id="", key_id="",
                                                      private_key_path="", provider="mosyle"))

    def post(path, operation, options=None):
        if options.get("os") == "ios":
            return {"status": "OK", "response": [{"devices": json.loads(text)}]}
        return {"status": "OK", "response": [{"status": "DEVICES_NOTFOUND"}]}

    client._post = post
    try:
        abapit = [device["attributes"]["custom_index"] for device in client.devices()]
    except TypeError:
        abapit = "TypeError"
    finally:
        client.close()
    seen, expected = set(), []
    for raw in json.loads(text):
        key = corrected_device_key(raw)
        if key and key in seen:
            continue
        if key:
            seen.add(key)
        expected.append(raw["custom_index"])
    if abapit != "TypeError" and abapit != expected:
        raise SystemExit(f"the corrected dedupe drifted from abapit's on {text}")
    case = {"function": "dedupe_devices", "input_json": text, "expected": expected}
    if abapit != expected:
        case["abapit"] = abapit
    return case


def device_columns(mosyle) -> list:
    """The raw columns the device list asks for (`specific_columns`): abapit's `_FIELD_MAP` and `_DATE_MAP` sources,
    in order, then the two its `_family` reads. abapit never sent the parameter (it took every column); this pins
    the list MosyleAdapter.deviceColumns sends, so a column can't be added unseen (verifier round 1). Whether
    Mosyle accepts each name is the Phase 7 live check's, not this golden's."""
    return list(mosyle._FIELD_MAP) + list(mosyle._DATE_MAP) + ["os", "device_type"]


def device_case(mosyle, raw: dict) -> dict:
    """adapt_device as an allowlist (defect 1, invariant 11): abapit's own output for the raw cut to the requested
    columns. That is abapit's output with its passed-through raw keys taken off the end (bypass codes, a raw
    `serialNumber` or `lastCheckIn` sent without its source, anything unknown), and an id that is a string."""
    abapit = jsonable(mosyle.adapt_device(raw))
    columns = device_columns(mosyle)
    expected = jsonable(mosyle.adapt_device({k: v for k, v in raw.items() if k in columns}))
    if not isinstance(expected["id"], str):
        expected["id"] = str(raw.get("serial_number") or raw.get("deviceudid"))
    kept, full = list(expected["attributes"].items()), list(abapit["attributes"].items())
    if kept != full[:len(kept)] or any(raw.get(k, object()) != v for k, v in full[len(kept):]):
        raise SystemExit(f"the allowlisted device is not abapit's with its passed-through keys cut: {raw}")
    case = {"function": "adapt_device", "input": raw, "expected": expected}
    if expected != abapit:
        case["abapit"] = abapit
    return case


def raw_mosyle_device(rng: random.Random) -> dict:
    os_value = rng.choice(["ios", "mac", "tvos", "visionos", "", "macos", "watchos", None])
    raw = {"serial_number": fake_serial(rng) if rng.random() < 0.9 else "",
           "deviceudid": "".join(rng.choices("0123456789abcdef", k=24)),
           "device_name": rng.choice(["Avery's Mac", "iPad 3", "", "Lobby TV"]),
           "device_model": rng.choice(["Mac15,12", "iPad12,1", "iPhone17,3", "AppleTV14,1", ""]),
           "device_model_name": rng.choice(["MacBook Air", "iPad (9th generation)", "", "iPhone 16"]),
           "osversion": rng.choice(["26.0", "18.6", ""]), "status": rng.choice(["enrolled", "pending"]),
           "is_supervised": rng.choice(["1", "0", 1, True]), "battery": rng.choice(["0.81", "1", None]),
           "total_disk": rng.choice(["64.0000000000", "256", None]),
           "date_last_beat": rng.choice([str(1_790_000_000 - rng.randint(0, 10**7)), "", None, "2026-10-01", "junk"]),
           "date_enroll": rng.choice([1_700_000_000, "1700000000", None]),
           "lostmode_status": rng.choice(["DISABLED", "ENABLED", "PENDINGTOENABLE"]),
           "tags": rng.choice(["", "a,b", None]), "custom_field": "x"}
    if os_value is not None:
        raw["os"] = os_value
    if rng.random() < 0.6:
        raw["activation_bypass"] = "TESTBYPASS-" + "".join(rng.choices(string.ascii_uppercase, k=8))
    if rng.random() < 0.4:
        raw["activation_bypass_mdm"] = "TESTBYPASSMDM-" + "".join(rng.choices(string.ascii_uppercase, k=8))
    if rng.random() < 0.3:
        raw["CurrentConsoleManagedUser"] = "avery"
    return {k: v for k, v in raw.items() if v is not None or rng.random() < 0.3}


def gen_mosyle(m: dict) -> None:
    mosyle = m["mosyle"]
    rng = random.Random(1007)
    # Draws added after the first golden use their own generators, so the cases drawn from `rng` never move.
    extras = random.Random(1008)
    cases = []
    devices = [raw_mosyle_device(rng) for _ in range(60)]
    # Phase 7a review L4: a serial that isn't a string (abapit's id is the raw value; a Resource's id is a string,
    # Python's `str()` of it), a family read by code points ("iPad" + U+0301 holds "ipad" for Python, not for
    # Swift's Character comparison), and a falsy 0.0 model name.
    devices += [{"serial_number": 123, "deviceudid": "u1", "os": "ios"}, {"serial_number": 1000.0, "os": "mac"},
                {"serial_number": True, "os": "mac"},
                {"serial_number": "", "deviceudid": "u2", "device_model": "iPad\u0301", "os": ""},
                {"serial_number": "TESTPAD00001", "device_model_name": 0.0, "device_model": "iPad12,1"},
                {"serial_number": "TESTPHONE001", "device_type": "IPHONE\u0301", "model_name": "x"}]
    # Verifier round 1: `in` when the word is the whole text or ends it, an `os` that only holds "ios", and raw keys
    # spelled like abapit's own names (abapit passed them through when their source was missing; here they are cut).
    devices += [{"serial_number": "TESTPAD00002", "device_type": "iPad", "os": ""},
                {"serial_number": "TESTPHONE002", "device_type": "iPhone"},
                {"serial_number": "TESTPHONE003", "device_model": "Xiphone", "os": ""},
                {"serial_number": "TESTPAD00003", "model_name": "myipad", "device_type": "x"},
                {"serial_number": "TESTIOSX0001", "os": "iosx", "device_model": "x"},
                {"serialNumber": "TESTCAMEL001", "deviceudid": "u3", "lastCheckIn": "2026-01-01", "productFamily": "Mac",
                 "managedBy": "Jamf", "deviceModel": "Fake", "osVersion": "1.0"},
                {"serial_number": "TESTCAMEL002", "serialNumber": "TESTOTHER001", "date_last_beat": "1700000000",
                 "lastCheckIn": "2001-01-01"}]
    for raw in devices:
        cases.append(device_case(mosyle, raw))
    cases.append({"function": "device_columns", "input": None, "expected": device_columns(mosyle)})
    for _ in range(25):
        raw = {k: v for k, v in {"iduser": rng.choice([str(rng.randint(1, 999)), rng.randint(1, 999), None]),
                                 "identifier": rng.choice(["avery", "", None]), "name": rng.choice(["Avery Chen", ""]),
                                 "email": rng.choice(["avery@example.com", "", None]),
                                 "managedappleid": rng.choice(["avery@appleid.example.com", None]),
                                 "type": rng.choice(["student", "teacher", None]), "usertype": rng.choice(["admin", None])}.items()
               if v is not None}
        raw.update(sensitive_extras(extras))
        cases.append(allowlisted({"function": "adapt_user", "input": raw}, jsonable(mosyle.adapt_user(raw)), USER_ATTRIBUTES))
    for raw in [{"iduser": "U1", "name": "Avery Chen", "email": "avery@example.com",
                 "activation_bypass": "TESTBYPASS-USER", "activation_bypass_mdm": "TESTBYPASSMDM-USER",
                 "password": "TESTPASSWORD", "token": "TESTTOKEN", "apikey": "TESTAPIKEY", "accessToken": "TESTACCESS",
                 "secret": "TESTSECRET", "custom_field": "x"},
                {"id": 7, "identifier": "kai", "type": 0.0, "usertype": "admin", "Password": "TESTPASSWORD2"}]:
        cases.append(allowlisted({"function": "adapt_user", "input": raw}, jsonable(mosyle.adapt_user(raw)), USER_ATTRIBUTES))
    for _ in range(25):
        raw = {k: v for k, v in {"idusergroup": rng.choice(["7", None]), "iddevicegroup": rng.choice(["9", 9, None]),
                                 "id": rng.choice(["11", None]), "name": rng.choice(["Sales", ""]),
                                 "device_numbers": rng.choice([3, "3", None]),
                                 "idusers_primary": rng.choice([["1", "2"], [], "x", None]),
                                 "members": rng.choice([5, None]), "os": rng.choice(["ios", "mac", None])}.items()
               if v is not None}
        kind = rng.choice(["userGroups", "deviceGroups"])
        raw.update(sensitive_extras(extras))
        cases.append(allowlisted({"function": "adapt_group", "input": {"raw": raw, "kind": kind}},
                                 jsonable(mosyle.adapt_group(raw, kind)), GROUP_ATTRIBUTES))
    for raw, kind in [({"idusergroup": "G1", "name": "Staff", "idusers_primary": ["U1"], "activation_bypass": "TESTBYPASS-G",
                        "password": "TESTPASSWORD", "token": "TESTTOKEN", "apikey": "TESTAPIKEY", "unknown": {"nested": "x"}},
                       "userGroups"),
                      ({"iddevicegroup": 9, "name": "Carts", "device_numbers": None, "members": 4, "os": "ios",
                        "token": "TESTTOKEN"}, "deviceGroups")]:
        cases.append(allowlisted({"function": "adapt_group", "input": {"raw": raw, "kind": kind}},
                                 jsonable(mosyle.adapt_group(raw, kind)), GROUP_ATTRIBUTES))
    cases.append({"function": "allowlists", "input": None, "expected": {"user": USER_ATTRIBUTES, "group": GROUP_ATTRIBUTES}})
    # Phase 7a review L4: the range's ends and the calendar before 1582 (Python's datetime is proleptic Gregorian;
    # Foundation's Gregorian calendar turns Julian there), int()'s underscores, Unicode digits and whitespace (any
    # script's decimal digits; U+001C to U+001F are str.isspace() but not int()'s), and str.isdigit()'s wider set
    # for the "already a date" test, whose `"-" in value` is by code points (a `-` with a combining mark counts).
    # Year 1 is `0001` because abapit's `%Y` is macOS's strftime, which pads (abapit ran there, and so does this).
    for value in [None, "", "1700000000", 1700000000, " 1700000000", "+1700000000", "0", "-1", "1.5", "abc",
                  "99999999999999999999", "2024-03-12", "2024-03-12 10:00:00", "2024-3-12", "01:00 PM - 03/12/2024",
                  "12:30 AM - 01/02/2025", "1e9", True, 3.7,
                  -62135596800, -62135596801, 253402300799, 253402300800, -12219292801, -12219292800, -30610224000,
                  -2208988800, 951782400, 4107542400, "-62135596800", "253402300800", False,
                  "1_700_000_000", "1__700", "_1700", "1700_", "+_1", "-0", "+0", "+-1", "+ 1", "1 2", "0x10", " ", "\u00a0",
                  "\u0661\u0662", "1\u0661", "\uff11\uff12", "\U0001d7ce\U0001d7cf", "\u0967\u0968", "\u0661_\u0662", "\u00b2",
                  "\x1c12", "12\x1f", "\x8512", "\u300012\u3000", " \t12\n", "\x0b12\x0c", "12\x00",
                  "\u0661\u0669\u0667\u0660-01-01", "\u00b2\u00b2\u00b2\u00b2-01", "\u2460\u2461\u2462\u2463-", "12-", "2024-\u0301"]:
        cases.append({"function": "to_iso", "input": {"value": value}, "expected": mosyle._to_iso(value)})
    # Verifier round 1: each of str.isspace()'s characters around the digits (int() strips ASCII's, maps the others
    # to a space and strips that, refuses U+001C to U+001F); a character that is neither a space nor a decimal digit
    # among them (a superscript, a zero-width space); a numeric that isn't a digit (a vulgar fraction, for
    # str.isdigit()); three digits before the dash; and digits on each side of the golden's `unicode`: Nag Mundari
    # (15.0) is a digit to abapit's Python, Garay (16.0) is not.
    for value in [chr(c) + "1700000000" + chr(c) for c in PY_WHITESPACE] + [
            "1\u00b2", "17\u200b00000000", "1\u00b5", "\u00bd\u00bd\u00bd\u00bd-01", "\u4e00\u4e8c\u4e09\u56db-01",
            "123a-x", "1\U0001e4f12", "\U0001e4f1\U0001e4f2\U0001e4f3\U0001e4f4-01", "1\U00010d402",
            "\U00010d40\U00010d41", "\U00010d40\U00010d41\U00010d42\U00010d43-01"]:
        cases.append({"function": "to_iso", "input": {"value": value}, "expected": mosyle._to_iso(value)})
    for text in ['{"value": 1e3}', '{"value": 1E3}', '{"value": -0.5}', '{"value": -0}', '{"value": 0.0}', '{"value": 1e20}',
                 '{"value": 9.2e18}', '{"value": NaN}', '{"value": Infinity}', '{"value": -Infinity}', '{"value": 1700000000.9}',
                 '{"value": 253402300799.5}', '{"value": -62135596800.9}', '{"value": -62135596801.5}', '{"value": []}',
                 '{"value": {}}', '{"value": 123456789012345678901234567890}']:
        cases.append(json_case("to_iso", text, lambda parsed: mosyle._to_iso(parsed["value"])))
    for value in ["01:00 PM - 03/12/2024", "12:30 AM - 01/02/2025", "12:05 PM - 12/31/2023", "13:00 PM - 03/12/2024",
                  "01:00 PM - 02/30/2024", "1:07 AM - 07/04/2026", "01:00 pm - 03/12/2024", "", None,
                  "99:59 PM - 03/12/2024", "00:30 PM - 03/12/2024", "00:00 AM - 03/12/2024", "12:00 PM - 03/12/2024",
                  "12:00 AM - 03/12/2024", "01:00 AM - 03/12/2024", "11:59 PM - 12/31/9999", "01:00 PM - 01/01/0001",
                  "01:00 PM - 03/12/0000", "01:00 PM - 02/29/1500", "01:00 PM - 02/29/1600", "01:00 PM - 02/29/1900",
                  "01:00 PM - 02/29/2000", "01:00 PM - 02/29/2023", "01:00 PM - 02/29/2024", "01:00 PM - 10/10/1582",
                  "01:00 PM - 00/12/2024", "01:00 PM - 13/12/2024", "01:00 PM - 03/00/2024", "01:00 PM - 03/32/2024",
                  "01:00 PM - 04/31/2024", "01:60 PM - 03/12/2024", "1:5 PM - 03/12/2024", "001:00 PM - 03/12/2024",
                  "01:00 PM - 03/12/2024\n", " 01:00 PM - 03/12/2024", "01:00  PM - 03/12/2024",
                  "\u0661:00 PM - 03/12/2024", "01:00 PM - 03/12/2024\u0301", 1700000000]:
        cases.append({"function": "compliance_time", "input": {"value": value}, "expected": compliance_time(value)})
    # Phase 7a review L4: Python's str() and bool() of what json.loads made of Mosyle's text. A JSON integer is an
    # int (exact, `-0` is 0); anything with a fraction or an exponent is a float, written by repr(): the shortest
    # digits that read back, positional from 1e-4 up to 1e16, else `1e+16` and `1e-05`. A list or a dict is its
    # repr(). The floats below are written to 17 digits, so the shortest form has to be found, not copied.
    texts = ["1e20", "1e3", "1E3", "0.1", "-0.0", "1e16", "1e15", "9.5e15", "123456789012345680.0", "5e-324", "1e-5",
             "0.0001", "0.00012", "100", "-0", "0", "-12", "12345678901234567890123", "1.5", "2.5e-7", "1e999", "-1e999",
             "1e-999", "NaN", "Infinity", "-Infinity", "9007199254740993", "9007199254740993.0", "1.7976931348623157e308",
             "4.9e-324", "0.30000000000000004", "1e22", "1e21", "123e-20", "1.0", "1.50", "-1.5e+300", "true", "false",
             "null", '"x"', '""', "[]", "{}", '[1, "a", null, true, false, 1e3, -0.0, [], {}]',
             '["it\'s", "say \\"hi\\"", "both \' and \\"", "back\\\\slash"]',
             '["\\u00e9", "\\u200b", "\\u0085", "\\u00a0", "\\t\\n\\r", "\\u0007", "\\u007f", "\\ud83d\\ude00", '
             '"\\udb40\\udc01", "\\u2028", "\\ue000", "\\u0378", "\\u00ff", "\\u0100"]',
             # Verifier round 1: U+2029, the last \u and the first \U escape, noncharacters, the last code point, and
             # characters on each side of the golden's `unicode` (15.0's print; 15.1's, 16.0's and 17.0's are
             # unassigned there, so escaped).
             '["\\u2029", "\\uffff", "\\ufffe", "\\ud800\\udc00", "\\udbff\\udfff", "\\ud839\\udcd0", "\\ud87a\\udff0", '
             '"\\ud803\\udd40", "\\u1acf", "\\u088f"]',
             '{"a": [1, {"b": null}], "k\'": "v", "": 1.25}']
    floats = random.Random(1009)
    for _ in range(300):
        value = struct.unpack("<d", struct.pack("<Q", floats.getrandbits(64)))[0]
        if math.isfinite(value):
            texts.append(f"{value:.17g}")
    for _ in range(150):
        texts.append(f"{floats.uniform(-1e6, 1e6):.17g}")
        texts.append(f"{round(floats.uniform(-1e4, 1e4), floats.randint(0, 6)):.17g}")
        texts.append(f"{floats.uniform(1e15, 1e17):.17g}")
        texts.append(f"{floats.uniform(1e-5, 1e-3):.17g}")
    for text in texts:
        cases.append(json_case("py_str", f'{{"value": {text}}}', lambda parsed: str(parsed["value"])))
    for text in ["0", "0.0", "-0.0", "-0", "0e5", "0E-3", "1e-400", "1", "0.5", "5e-324", "1e400", "NaN", "Infinity",
                 "-Infinity", '""', '"0"', '" "', "[]", "[0]", "{}", '{"a": 0}', "true", "false", "null"]:
        cases.append(json_case("py_truthy", f'{{"value": {text}}}', lambda parsed: bool(parsed["value"])))
    # Phase 7a review L4: a numeric serial is deduplicated as abapit's set compared it: by value (123, 123.0 and
    # 1.23e2 are one key; "123" is another; True is 1), a string by its code points, a NaN matching the NaN json
    # hands out every time, and a list or an object refused (abapit's TypeError, the corrected key above).
    # Each row as Mosyle would write it; `custom_index` (first) names it in the expected list.
    for rows in [['{"serial_number": 123, "deviceudid": "a"}', '{"serial_number": 123, "deviceudid": "b"}',
                  '{"serial_number": "123", "deviceudid": "c"}', '{"serial_number": 123.0}', '{"serial_number": 1.23e2}'],
                 ['{"serial_number": true}', '{"serial_number": 1}', '{"serial_number": 1.0}', '{"serial_number": "1"}'],
                 ['{"serial_number": "", "deviceudid": "U"}', '{"serial_number": 0, "deviceudid": "U"}',
                  '{"serial_number": null, "deviceudid": "U"}', '{"serial_number": false, "deviceudid": "V"}',
                  '{"serial_number": 0.0, "deviceudid": ""}', '{"serial_number": "", "deviceudid": ""}', '{}'],
                 ['{"serial_number": "\\u00e9"}', '{"serial_number": "e\\u0301"}', '{"serial_number": "\\u00e9"}'],
                 ['{"serial_number": 9007199254740993}', '{"serial_number": 9007199254740992.0}',
                  '{"serial_number": 9007199254740992}', '{"serial_number": 1e20}', '{"serial_number": 100000000000000000000}'],
                 ['{"serial_number": 1e300}', f'{{"serial_number": {int(1e300)}}}', f'{{"serial_number": 1{"0" * 300}}}'],
                 ['{"serial_number": NaN}', '{"serial_number": NaN}', '{"serial_number": Infinity}',
                  '{"serial_number": 1e999}', '{"serial_number": -Infinity}'],
                 ['{"serial_number": 0.1}', '{"serial_number": 0.10000000000000001}', '{"serial_number": 0.2}',
                  '{"serial_number": -5}', '{"serial_number": -5.0}', '{"serial_number": -0.5}'],
                 ['{"serial_number": ["A"]}', '{"serial_number": "A"}', '{"serial_number": "A"}'],
                 ['{"serial_number": {"a": 1}, "deviceudid": "U"}', '{"deviceudid": "U"}'],
                 # Verifier round 1: a string serial that spells a number's key is still a string.
                 ['{"serial_number": "i123"}', '{"serial_number": 123}', '{"serial_number": "f0.5"}',
                  '{"serial_number": 0.5}', '{"serial_number": "123"}']]:
        text = "[" + ", ".join(f'{{"custom_index": {i}' + (", " + row[1:] if row != "{}" else "}")
                               for i, row in enumerate(rows)) + "]"
        cases.append(dedupe_case(m, text))
    for _ in range(30):
        def logs(kind):
            out = []
            for i in range(rng.randint(0, 3)):
                stamp = rng.choice([str(1_790_000_000 - rng.randint(0, 10**6)), "01:00 PM - 03/12/2024",
                                    "2026-10-01T10:00:00Z", "", None])
                out.append({"compliance": {"Timestamp": stamp, "RuleName": f"Rule {i}", "Status": "Failed",
                                           "DeviceName": "Mac", "SerialNumber": fake_serial(rng), "E-mail": "avery@example.com"},
                            "zero_trust": {"Timestamp": stamp, "Application": rng.choice(["Slack", None]),
                                           "FileName": "a.dmg", "Action": "Blocked", "Device": "Mac", "Source": "kai"},
                            "action_logs": {"ActionDate": stamp, "Action": "Wipe requested", "UserName": rng.choice(["admin", None]),
                                            "E-mail": "admin@example.com"},
                            "dns": {"Timestamp": stamp, "Domain": "example.com", "Action": "Allowed", "Device": "iPad"},
                            "av": {"Timestamp": stamp, "FileName": "x.exe", "Status": "Quarantined", "DeviceName": "Mac",
                                   "SerialNumber": fake_serial(rng)}}[kind])
            return out
        response = {}
        if rng.random() < 0.7:
            response["compliance"] = {"mac": {"Logs": logs("compliance")}, "ios": {"Logs": logs("compliance")}}
        if rng.random() < 0.5:
            response["zero_trust"] = rng.choice([{"Events": {"Logs": logs("zero_trust")}}, {"Logs": logs("zero_trust")}])
        if rng.random() < 0.5:
            response["action_logs"] = {"Logs": logs("action_logs")}
        if rng.random() < 0.4:
            response["dns"] = rng.choice([logs("dns"), {"Logs": logs("dns")}])
        if rng.random() < 0.4:
            response["av"] = {"Logs": logs("av")}
        cases.append(logs_case(mosyle, response))
    # Phase 7a review L4: a stamp that is a number as Mosyle wrote it, so its str() is Python's (`1e+20`).
    for text in ['{"dns": [{"Timestamp": 1e20, "Domain": "a.example.com"}]}',
                 '{"dns": [{"Timestamp": 1e15, "Domain": "b.example.com"}, {"Timestamp": 0.0, "Domain": "c.example.com"}]}',
                 '{"av": {"Logs": [{"Timestamp": 1e3, "FileName": "x.exe"}]}}',
                 '{"action_logs": {"Logs": [{"ActionDate": NaN, "Action": "A"}, {"ActionDate": ["x", 1e3], "Action": "B"}]}}',
                 '{"compliance": {"mac": {"Logs": [{"Timestamp": "13:00 PM - 03/12/2024", "RuleName": "R"},'
                 ' {"Timestamp": "01:00 PM - 02/29/1500", "RuleName": "S"}]}}}',
                 '{"zero_trust": {"Logs": [{"Timestamp": -62135596800, "Application": "App"},'
                 ' {"Timestamp": -12219292801, "Application": "Old"}]}}',
                 # Junk where a log belongs: abapit raised AttributeError, here it is skipped.
                 '{"compliance": {"mac": {"Logs": ["x", {"Timestamp": "1700000000", "RuleName": "R"}]}, "ios": "x"}}',
                 '{"action_logs": {"Logs": {"a": 1}}, "dns": [{"Timestamp": "1700000001", "Domain": "d"}, "x"]}',
                 '{"zero_trust": {"Events": {"Logs": ["x"]}, "Logs": [{"Timestamp": "1700000002", "Application": "Z"}]}}']:
        cases.append(logs_case(mosyle, json.loads(text), text))
    write("mosyle", {**header(1007), "cases": cases})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--abapit", type=Path, required=True, help="a checkout of abapit holding the pinned commit")
    args = parser.parse_args()
    modules = load_abapit(args.abapit.resolve())
    gen_serials(modules)
    gen_assign(modules)
    gen_blueprint_relationships(modules)
    gen_reports(modules)
    gen_csv(modules)
    gen_diff(modules)
    gen_keys_and_claims(modules)
    gen_mosyle(modules)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
