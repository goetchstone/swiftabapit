#!/usr/bin/env python3
"""Generate the configuration-profile schema contract from apple/device-management (plan §3.10, §2.1).

Apple's device-management repository describes every MDM profile payload as YAML: its payload type, the OS
versions that support it, and every payload key with its type, value type and presence. This script reads
`mdm/profiles/*.yaml` at one pinned commit and writes, deterministically (sorted, no timestamps):

    Contracts/device-management/profiles-<version>.json

Now: the contract `ProfileText`'s masking is held to (a key Apple says holds a secret is masked; any other key
is shown, or is on the recorded over-mask list). Phase 5: the validation of a custom setting before upload.

Downloaded files are DATA: YAML read with `yaml.safe_load` and nothing else, capped in size and count, fetched
only over HTTPS from api.github.com (the tree, once) and raw.githubusercontent.com (each file at the pinned
commit), with no redirect followed. Each file's bytes are checked against the tree's git blob hash before they
are read. PyYAML runs only in a dev venv; the output is committed, so nothing in CI needs it:

    <a venv with PyYAML>/bin/python -I -B scripts/device_management_schemas.py --out Contracts/device-management

Apple's licence (MIT) travels with the data, in the output's `license` field.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

REPO = "apple/device-management"
COMMIT = "09f249a06e7e3289930bf6d05f38fb562f748ebf"   # the release branch's "Release-v27.0" (plan Appendix E)
RELEASE = "Release-v27.0"
VERSION = "27.0"
HOSTS = {"api.github.com", "raw.githubusercontent.com"}
MAX_FILES = 400           # 127 profile schemas at 27.0
MAX_BYTES = 2 * 1024 * 1024
DELAY = 0.05
PLATFORMS = ["iOS", "macOS", "tvOS", "visionOS", "watchOS"]


class NoRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect is refused before it is followed, so no request leaves the two hosts."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SystemExit(f"{req.full_url} redirected to {newurl}; refusing to follow")


OPENER = urllib.request.build_opener(NoRedirects)


def fetch(url: str) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in HOSTS:
        raise SystemExit(f"refusing to fetch {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "swiftabapit-contracts/1"})
    with OPENER.open(request, timeout=30) as response:
        body = response.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise SystemExit(f"{url} is larger than {MAX_BYTES} bytes")
    time.sleep(DELAY)
    return body


def blob_sha(body: bytes) -> str:
    """Git's object id for a file's bytes: what the tree names, so a file that isn't the commit's is refused."""
    return hashlib.sha1(b"blob %d\0" % len(body) + body).hexdigest()


def keys_of(items, prefix: list[str], seen: tuple[int, ...], out: list[dict]) -> None:
    """Every payload key, depth first, with its path. A schema that names itself through a YAML anchor (an allow list's
    sub-apps, the Home Screen's pages) is marked `recursive` where it repeats, not walked again."""
    for item in items or []:
        if not isinstance(item, dict) or "key" not in item:
            continue
        path = prefix + [str(item["key"])]
        key = {"path": path, "type": item.get("type"), "valuetype": item.get("valuetype") or item.get("subtype"),
               "presence": item.get("presence")}
        if id(item) in seen:
            out.append({**key, "recursive": True})
            continue
        out.append(key)
        keys_of(item.get("subkeys"), path, seen + (id(item),), out)


def supported(payload: dict) -> dict:
    """The OS each platform added the payload in, for the platforms that have it ("n/a" left out)."""
    os = payload.get("supportedOS") or {}
    return {name: str(os[name]["introduced"]) for name in PLATFORMS
            if isinstance(os.get(name), dict) and str(os[name].get("introduced", "n/a")) != "n/a"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, required=True, help="Contracts/device-management")
    args = parser.parse_args()
    tree = json.loads(fetch(f"https://api.github.com/repos/{REPO}/git/trees/{COMMIT}?recursive=1"))
    if tree.get("truncated"):
        raise SystemExit("the tree listing is truncated")
    blobs = {t["path"]: t["sha"] for t in tree["tree"] if t["type"] == "blob"}
    files = sorted(p for p in blobs if p.startswith("mdm/profiles/") and p.endswith(".yaml"))
    if not files or len(files) > MAX_FILES:
        raise SystemExit(f"{len(files)} profile schemas; expected 1 to {MAX_FILES}")
    whole = hashlib.sha256()
    payloads = []
    for path in files + ["LICENSE.txt"]:
        body = fetch(f"https://raw.githubusercontent.com/{REPO}/{COMMIT}/{path}")
        if blob_sha(body) != blobs[path]:
            raise SystemExit(f"{path}: its bytes aren't the commit's ({blob_sha(body)} != {blobs[path]})")
        if path == "LICENSE.txt":
            license_text = body.decode("utf-8")
            continue
        whole.update(path.encode() + b"\0" + body)
        doc = yaml.safe_load(body)
        payload = doc.get("payload") or {}
        keys: list[dict] = []
        keys_of(doc.get("payloadkeys"), [], (), keys)
        payloads.append({"file": path, "sha256": hashlib.sha256(body).hexdigest(), "payloadtype": payload.get("payloadtype"),
                         "supportedOS": supported(payload), "keys": keys})
    result = {
        "source": f"https://github.com/{REPO}",
        "commit": COMMIT,
        "release": RELEASE,
        "sha256": whole.hexdigest(),
        "counts": {"files": len(payloads), "keys": sum(len(p["keys"]) for p in payloads)},
        "license": license_text,
        "payloads": payloads,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    out = args.out / f"profiles-{VERSION}.json"
    out.write_text(json.dumps(result, indent=1, ensure_ascii=True) + "\n")
    print(f"{result['counts']} → {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
