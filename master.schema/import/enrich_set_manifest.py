#!/usr/bin/env python3
"""
BrickTrackr SET manifest enrichment collector.

Sources:
- Rebrickable set page: building instruction PDF evidence.
- BrickLink set inventory: sticker-sheet evidence.
- Optional curated JSON: packaging evidence.

All canonical writes go through import.upsert_set_manifest_component(...).
The importer login never writes definition tables directly.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import time
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin

import psycopg
import requests

UA = "BrickTrackr-Manifest-Enrichment/1.0"
RB_BASE = "https://rebrickable.com"
BL_BASE = "https://www.bricklink.com"

PDF_RE = re.compile(r"\.pdf(?:\?|$)", re.I)
STICKER_RE = re.compile(r"\b([A-Za-z0-9._-]*stk\d+[A-Za-z0-9._-]*)\b", re.I)


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, str]] = []
        self._href: str | None = None
        self._text: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag.lower() == "a":
            self._href = dict(attrs).get("href")
            self._text = []

    def handle_data(self, data: str) -> None:
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "a" and self._href is not None:
            self.links.append((self._href, " ".join(self._text).strip()))
            self._href = None
            self._text = []


def get(session: requests.Session, url: str) -> str:
    last = None
    for attempt in range(1, 5):
        try:
            r = session.get(url, timeout=(20, 90))
            if r.status_code == 429:
                wait = min(30, 2 ** attempt)
                time.sleep(wait)
                continue
            r.raise_for_status()
            return r.text
        except Exception as exc:
            last = exc
            if attempt == 4:
                raise
            time.sleep(min(10, 2 ** attempt))
    raise RuntimeError(str(last))


def rebrickable_instructions(session: requests.Session, set_num: str) -> list[dict]:
    url = f"{RB_BASE}/sets/{set_num}/"
    body = get(session, url)
    parser = LinkParser()
    parser.feed(body)

    found: dict[str, dict] = {}
    for href, label in parser.links:
        absolute = urljoin(url, href)
        if PDF_RE.search(absolute):
            key = absolute.split("?", 1)[0]
            found[key] = {
                "kind": "INSTRUCTIONS",
                "source_code": "REBRICKABLE",
                "external_id": key.rsplit("/", 1)[-1],
                "display_name": label or f"Instructions for {set_num}",
                "source_url": absolute,
                "quantity": 1,
                "payload": {"set_num": set_num, "page_url": url},
            }

    # Some Rebrickable pages expose instruction links through /instructions/.
    # Preserve those as evidence when a direct PDF is not present in HTML.
    if not found:
        for href, label in parser.links:
            absolute = urljoin(url, href)
            if "/instructions/" in absolute:
                key = absolute.rstrip("/").rsplit("/", 1)[-1]
                found[absolute] = {
                    "kind": "INSTRUCTIONS",
                    "source_code": "REBRICKABLE",
                    "external_id": key,
                    "display_name": label or f"Instructions for {set_num}",
                    "source_url": absolute,
                    "quantity": 1,
                    "payload": {"set_num": set_num, "page_url": url},
                }

    return list(found.values())


def bricklink_stickers(session: requests.Session, set_num: str) -> list[dict]:
    url = f"{BL_BASE}/catalogItemInv.asp?S={set_num}"
    body = html.unescape(get(session, url))
    plain = re.sub(r"<[^>]+>", " ", body)
    plain = re.sub(r"\s+", " ", plain)

    found: dict[str, dict] = {}
    for match in STICKER_RE.finditer(plain):
        ext = match.group(1)
        window = plain[max(0, match.start()-140): match.end()+220]
        if "sticker sheet" not in window.lower():
            continue
        found[ext.lower()] = {
            "kind": "STICKER_SHEET",
            "source_code": "BRICKLINK",
            "external_id": ext,
            "display_name": f"Sticker Sheet for Set {set_num.split('-',1)[0]}",
            "source_url": url,
            "quantity": 1,
            "payload": {"set_num": set_num, "evidence": window.strip()},
        }
    return list(found.values())


def curated_packaging(path: Path | None, set_num: str) -> list[dict]:
    if path is None:
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    rows = data if isinstance(data, list) else data.get("packaging", [])
    out = []
    for row in rows:
        row_set = str(row.get("set_num", "")).strip()
        if row_set not in {set_num, set_num.split("-", 1)[0]}:
            continue
        ext = str(row.get("external_id") or f"{set_num}-BOX").strip()
        out.append({
            "kind": "PACKAGING",
            "source_code": str(row.get("source_code") or "CURATED").upper(),
            "external_id": ext,
            "display_name": row.get("display_name") or f"Packaging for {set_num}",
            "source_url": row.get("source_url"),
            "quantity": int(row.get("quantity") or 1),
            "payload": row,
        })
    return out


def db_set_num(conn: psycopg.Connection, entered: str) -> str:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT ei.external_id
            FROM catalog.external_identifiers ei
            JOIN reference.external_sources es ON es.source_id = ei.source_id
            JOIN catalog.items ci ON ci.catalog_item_id = ei.catalog_item_id
            WHERE es.source_code = 'REBRICKABLE'
              AND ei.entity_namespace = 'SET'
              AND ci.item_kind = 'SET'::catalog.item_kind
              AND (
                  ei.external_id = %s
                  OR ei.external_id = %s || '-1'
                  OR split_part(ei.external_id, '-', 1) = %s
              )
            ORDER BY CASE
                WHEN ei.external_id = %s || '-1' THEN 0
                WHEN ei.external_id = %s THEN 1
                ELSE 2
            END
            LIMIT 1
            """,
            (entered, entered, entered, entered, entered),
        )
        row = cur.fetchone()
    if not row:
        raise RuntimeError(f"canonical SET {entered!r} not found")
    return row[0]


def upsert(conn: psycopg.Connection, set_num: str, row: dict) -> dict:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT import.upsert_set_manifest_component(
                %s,%s,%s,%s,%s,%s,%s,%s::jsonb
            )
            """,
            (
                set_num,
                row["kind"],
                row["source_code"],
                row["external_id"],
                row.get("display_name"),
                row.get("source_url"),
                row.get("quantity", 1),
                json.dumps(row.get("payload") or {}),
            ),
        )
        return cur.fetchone()[0]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--set-num", required=True, help="Box number, e.g. 72005")
    p.add_argument("--dsn", default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"))
    p.add_argument("--packaging-json", type=Path)
    p.add_argument("--skip-rebrickable", action="store_true")
    p.add_argument("--skip-bricklink", action="store_true")
    return p.parse_args()


def main() -> int:
    a = parse_args()
    if not a.dsn:
        print("[FAIL] BRICKTRACKR_IMPORT_DATABASE_URL / --dsn is required", file=sys.stderr)
        return 2

    session = requests.Session()
    session.headers.update({"User-Agent": UA, "Accept": "text/html,application/xhtml+xml"})

    with psycopg.connect(a.dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user::text")
            login = cur.fetchone()[0]
            cur.execute("SELECT pg_has_role(%s,'brktrkr_import','MEMBER')", (login,))
            if not cur.fetchone()[0]:
                raise RuntimeError(f"{login!r} is not a brktrkr_import member")
            cur.execute("SET ROLE brktrkr_import")
        conn.commit()

        canonical_set_num = db_set_num(conn, a.set_num.strip())
        print(f"[SET] {a.set_num} -> {canonical_set_num}")

        rows: list[dict] = []
        if not a.skip_rebrickable:
            instructions = rebrickable_instructions(session, canonical_set_num)
            print(f"[SOURCE] Rebrickable instructions: {len(instructions)}")
            rows.extend(instructions)

        if not a.skip_bricklink:
            stickers = bricklink_stickers(session, canonical_set_num)
            print(f"[SOURCE] BrickLink sticker sheets: {len(stickers)}")
            rows.extend(stickers)

        packaging = curated_packaging(a.packaging_json, canonical_set_num)
        print(f"[SOURCE] Curated packaging: {len(packaging)}")
        rows.extend(packaging)

        if not rows:
            print("[WARN] No enrichment evidence found.")
            return 0

        with conn.transaction():
            for row in rows:
                result = upsert(conn, canonical_set_num, row)
                print(
                    f"[UPSERT] {result['component_kind']:<14} "
                    f"{result['source_code']:<12} {result['external_id']}"
                )

    print("[PASS] SET manifest enrichment complete")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
