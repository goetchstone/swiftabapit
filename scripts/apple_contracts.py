#!/usr/bin/env python3
"""Generate the Apple API contract manifests from Apple's DocC JSON (plan §3.10).

Apple publishes no OpenAPI spec for the Apple Business API or the Apple School Manager API, but every
documentation page is machine-readable JSON under
https://developer.apple.com/tutorials/data/documentation/<root>/<slug>.json, with the endpoint
(`restEndpoint`), its parameters (`restParameters`, with `allowedValues`/`maximum`), body
(`restBody`), status codes (`restResponses`), object properties (`properties`), enum values
(`possibleValues`) and example requests and responses (code listings).

This crawler walks both documentation roots and writes, deterministically (sorted, no timestamps, so a
re-run that finds nothing new changes nothing):

    Contracts/apple/business-<version>.json   endpoints, objects, enums
    Contracts/apple/school-<version>.json
    Tests/Fixtures/docc/<scope>/<slug>.response.json   each JSON example, as Apple wrote it
    Tests/Fixtures/docc/<scope>/<slug>.request.json    each JSON request body found in an example

Downloaded pages are DATA: parsed as JSON and nothing else, capped in size and count, fetched only from
developer.apple.com over HTTPS, and never written anywhere but the outputs above. Run it isolated
(`python3 -I -B`), standard library only:

    python3 -I -B scripts/apple_contracts.py --out Contracts/apple --examples Tests/Fixtures/docc

The weekly drift job (.github/workflows/contracts-drift.yml) runs it and opens an issue with the diff.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HOST = "developer.apple.com"
DATA = f"https://{HOST}/tutorials/data"
ROOTS = {"business": "applebusinessapi", "school": "appleschoolmanagerapi"}
MAX_PAGES = 1500          # per root; both roots are a few hundred pages today
MAX_BYTES = 4 * 1024 * 1024
DELAY = 0.05              # be gentle with Apple's CDN


def fetch(url_path: str) -> dict | None:
    """One DocC page as JSON, or None when it doesn't exist. Only developer.apple.com, only HTTPS."""
    url = f"{DATA}{url_path}.json"
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != HOST:
        raise SystemExit(f"refusing to fetch {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "swiftabapit-contracts/1"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            final = urllib.parse.urlparse(response.geturl())
            if final.hostname != HOST or final.scheme != "https":
                raise SystemExit(f"{url} redirected off {HOST}: {response.geturl()}")
            body = response.read(MAX_BYTES + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    if len(body) > MAX_BYTES:
        raise SystemExit(f"{url} is larger than {MAX_BYTES} bytes")
    time.sleep(DELAY)
    return json.loads(body)


def text_of(tokens) -> str:
    """The plain text of a DocC token or inline-content list."""
    if isinstance(tokens, str):
        return tokens
    out = []
    for token in tokens or []:
        if not isinstance(token, dict):
            continue
        if "text" in token:
            out.append(str(token["text"]))
        elif "inlineContent" in token:
            out.append(text_of(token["inlineContent"]))
        elif "code" in token and isinstance(token["code"], str):
            out.append(token["code"])
    return "".join(out)


def prose(content) -> str:
    """A paragraph list's text, whitespace collapsed."""
    parts = [text_of(block.get("inlineContent")) for block in content or [] if isinstance(block, dict)]
    return re.sub(r"\s+", " ", " ".join(parts)).strip()


def type_of(type_tokens) -> dict:
    """A property's or parameter's type: its text, and the DocC type it names, if any."""
    found = {"text": text_of(type_tokens)}
    names = [t.get("text") for t in type_tokens or [] if isinstance(t, dict) and t.get("kind") == "typeIdentifier"]
    if names:
        found["types"] = names
    return found


def constraints(attributes) -> dict:
    found = {}
    for attribute in attributes or []:
        kind = attribute.get("kind")
        if kind == "allowedValues":
            found["allowedValues"] = list(attribute.get("values", []))
        elif kind in ("maximum", "minimum", "maximumLength", "minimumLength", "default"):
            found[kind] = attribute.get("value")
        elif kind == "allowedTypes":
            found["allowedTypes"] = [text_of(t) for t in attribute.get("values", [])]
    return found


def code_listings(sections) -> list[dict]:
    """Every code listing on the page, with the tab it sits under (Request / Response)."""
    listings = []

    def walk(node, tab):
        if isinstance(node, dict):
            if node.get("type") == "codeListing":
                listings.append({"tab": tab, "syntax": node.get("syntax"), "code": "\n".join(node.get("code", []))})
                return
            if "tabs" in node:
                for entry in node["tabs"]:
                    for item in entry.get("content", []):
                        walk(item, entry.get("title", tab))
                return
            for value in node.values():
                walk(value, tab)
        elif isinstance(node, list):
            for value in node:
                walk(value, tab)

    walk(sections, None)
    return listings


def json_in(code: str):
    """The JSON a listing holds: the listing itself, or the body a curl example sends (-d '…')."""
    try:
        return json.loads(code)
    except ValueError:
        pass
    match = re.search(r"(?:-d|--data(?:-raw)?)\s+'(.*)'", code, re.S)
    if match:
        try:
            return json.loads(match.group(1))
        except ValueError:
            return None
    return None


def parse_page(page: dict, slug: str) -> tuple[str, dict]:
    """(kind, record) for one page: an endpoint, an object, an enum, or other."""
    meta = page.get("metadata", {})
    sections = page.get("primaryContentSections", [])
    by_kind = {}
    for section in sections:
        by_kind.setdefault(section.get("kind"), []).append(section)
    record = {"title": meta.get("title", ""), "slug": slug}
    abstract = text_of(page.get("abstract"))
    if abstract:
        record["abstract"] = re.sub(r"\s+", " ", abstract).strip()
    if meta.get("platforms"):
        record["introducedAt"] = meta["platforms"][0].get("introducedAt")
        if meta["platforms"][0].get("deprecated"):
            record["deprecated"] = True

    if "restEndpoint" in by_kind:
        tokens = by_kind["restEndpoint"][0].get("tokens", [])
        method = next((t["text"] for t in tokens if t.get("kind") == "method"), "")
        base = next((t["text"] for t in tokens if t.get("kind") == "baseURL"), "")
        path = "".join(t["text"] for t in tokens if t.get("kind") in ("path", "parameter"))
        record.update({"method": method, "baseURL": base, "path": "/" + path.lstrip("/")})
        params = []
        for section in by_kind.get("restParameters", []):
            for item in section.get("items", []):
                entry = {"name": item.get("name"), "in": section.get("source"), "required": bool(item.get("required")),
                         "type": type_of(item.get("type"))}
                entry.update(constraints(item.get("attributes")))
                text = prose(item.get("content"))
                if text:
                    entry["description"] = text
                params.append(entry)
        record["parameters"] = sorted(params, key=lambda p: (p["in"] or "", p["name"] or ""))
        for section in by_kind.get("restBody", []):
            record["body"] = {"mimeType": section.get("mimeType"), "type": type_of(section.get("bodyContentType")),
                              "parameters": [dict({"name": i.get("name"), "required": bool(i.get("required")),
                                                   "type": type_of(i.get("type"))}, **constraints(i.get("attributes")))
                                             for i in section.get("parameters", [])]}
        responses = []
        for section in by_kind.get("restResponses", []):
            for item in section.get("items", []):
                responses.append({"status": item.get("status"), "reason": item.get("reason", ""),
                                  "type": type_of(item.get("type"))})
        record["responses"] = sorted(responses, key=lambda r: r["status"] or 0)
        return "endpoint", record

    if "properties" in by_kind:
        props = []
        for section in by_kind["properties"]:
            for item in section.get("items", []):
                entry = {"name": item.get("name"), "required": bool(item.get("required")), "type": type_of(item.get("type"))}
                entry.update(constraints(item.get("attributes")))
                if item.get("deprecated"):
                    entry["deprecated"] = True
                props.append(entry)
        record["properties"] = sorted(props, key=lambda p: p["name"] or "")
        return "object", record

    if "possibleValues" in by_kind:
        record["values"] = [v.get("name") for v in by_kind["possibleValues"][0].get("values", [])]
        return "enum", record

    return "other", record


def crawl(root: str) -> dict:
    """Every page under /documentation/<root>/ reachable from the root's references."""
    prefix = f"/documentation/{root}"
    start = fetch(prefix)
    if start is None:
        raise SystemExit(f"no DocC root at {prefix}")
    version = (start.get("metadata", {}).get("platforms") or [{}])[0].get("introducedAt", "unknown")
    pages, queue, seen = {}, [], {prefix}

    def enqueue(page):
        for ref in (page.get("references") or {}).values():
            url = ref.get("url") if isinstance(ref, dict) else None
            if isinstance(url, str) and url.lower().startswith(prefix + "/") and url.lower() not in seen:
                seen.add(url.lower())
                queue.append(url.lower())

    enqueue(start)
    while queue:
        if len(pages) >= MAX_PAGES:
            raise SystemExit(f"{root}: more than {MAX_PAGES} pages; raise MAX_PAGES after checking why")
        url = queue.pop(0)
        page = fetch(url)
        if page is None:
            continue
        pages[url[len(prefix) + 1:]] = page
        enqueue(page)
    return {"version": version, "pages": pages}


def manifest(scope: str, root: str, crawled: dict, examples_dir: Path | None) -> dict:
    endpoints, objects, enums = [], {}, {}
    for slug in sorted(crawled["pages"]):
        page = crawled["pages"][slug]
        kind, record = parse_page(page, slug)
        if kind == "endpoint":
            examples = []
            for listing in code_listings(page.get("primaryContentSections", [])):
                body = json_in(listing["code"])
                if body is None:
                    continue
                role = "request" if (listing["tab"] or "").lower().startswith("request") else "response"
                examples.append(role)
                if examples_dir is not None:
                    out = examples_dir / scope / f"{slug.replace('/', '_')}.{role}.json"
                    out.parent.mkdir(parents=True, exist_ok=True)
                    out.write_text(json.dumps(body, indent=2, sort_keys=True, ensure_ascii=True) + "\n")
            record["examples"] = sorted(set(examples))
            endpoints.append(record)
        elif kind == "object":
            objects[record["title"] or slug] = record
        elif kind == "enum":
            enums[record["title"] or slug] = record
    endpoints.sort(key=lambda e: (e["path"], e["method"]))
    return {
        "source": f"https://{HOST}/documentation/{root}",
        "scope": scope,
        "version": crawled["version"],
        "generator": "scripts/apple_contracts.py",
        "counts": {"endpoints": len(endpoints), "objects": len(objects), "enums": len(enums)},
        "endpoints": endpoints,
        "objects": dict(sorted(objects.items())),
        "enums": dict(sorted(enums.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, required=True, help="Contracts/apple")
    parser.add_argument("--examples", type=Path, help="Tests/Fixtures/docc")
    parser.add_argument("--scope", choices=sorted(ROOTS), action="append", help="default: both")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for scope in args.scope or sorted(ROOTS):
        root = ROOTS[scope]
        if args.examples is not None:
            for old in (args.examples / scope).glob("*.json"):
                old.unlink()
        crawled = crawl(root)
        result = manifest(scope, root, crawled, args.examples)
        for old in args.out.glob(f"{scope}-*.json"):
            old.unlink()
        path = args.out / f"{scope}-{result['version']}.json"
        path.write_text(json.dumps(result, indent=1, sort_keys=False, ensure_ascii=True) + "\n")
        print(f"{scope}: {result['counts']} → {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
