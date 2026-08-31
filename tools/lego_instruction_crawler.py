#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import os
import random
import re
import shutil
import sys
import time
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlparse

import psycopg
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError

VERSION = "1.6.0"
BASE_URL = "https://www.lego.com/en-us/service/building-instructions"
TERMINAL = {"FOUND", "NO_INSTRUCTIONS", "NOT_FOUND"}
PDF_RE = re.compile(r'(?P<u>https?://[^\\s"\'<>\\\\]+?\\.pdf(?:\\?[^\\s"\'<>\\\\]*)?|/[^\\s"\'<>\\\\]+?\\.pdf(?:\\?[^\\s"\'<>\\\\]*)?)', re.I)
YEAR_RE = re.compile(r"\\bYear\\s*:\\s*(19\\d{2}|20\\d{2})\\b", re.I)
FRAC_RE = re.compile(r"\\((\\d+)\\s*/\\s*(\\d+)\\)")
PDF_ID_RE = re.compile(r"/([^/?#]+)\\.pdf(?:[?#]|$)", re.I)


def now():
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def clean(s):
    if s is None:
        return None
    s = re.sub(r"\\s+", " ", html.unescape(s)).strip()
    return s or None


class Parser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []
        self.href = None
        self.link_text = []
        self.in_h1 = False
        self.h1_text = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if tag.lower() == "a":
            self.href = d.get("href")
            self.link_text = []
        elif tag.lower() == "h1":
            self.in_h1 = True

    def handle_data(self, data):
        if data.strip():
            self.text.append(data)
        if self.href is not None:
            self.link_text.append(data)
        if self.in_h1:
            self.h1_text.append(data)

    def handle_endtag(self, tag):
        if tag.lower() == "a" and self.href is not None:
            self.links.append((self.href, clean(" ".join(self.link_text)) or ""))
            self.href = None
            self.link_text = []
        elif tag.lower() == "h1":
            self.in_h1 = False

    @property
    def h1(self):
        return clean(" ".join(self.h1_text))

    @property
    def plain(self):
        return clean(" ".join(self.text)) or ""


def parse_args():
    p = argparse.ArgumentParser(description="Build durable LEGO instruction snapshots for BrickTrackr.")
    p.add_argument("--dsn", default=os.getenv("BRICKTRACKR_DATABASE_URL") or os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"))
    p.add_argument("--output-dir", type=Path, default=Path("data/lego-instructions"))
    p.add_argument("--years", type=int, default=10)
    p.add_argument("--start-year", type=int, default=None, help="Optional top release year; defaults to latest year in BrickTrackr.")
    p.add_argument("--min-delay", type=float, default=3.0)
    p.add_argument("--max-delay", type=float, default=5.0)
    p.add_argument("--timeout", type=int, default=60)
    p.add_argument("--max-attempts", type=int, default=5)
    p.add_argument("--base-url", default=BASE_URL)
    p.add_argument("--user-agent", default=os.getenv("BRICKTRACKR_LEGO_USER_AGENT", "BrickTrackr-LEGO-Instructions/1.0"))
    p.add_argument("--retry-errors", action="store_true")
    p.add_argument("--restart", action="store_true")
    p.add_argument("--limit", type=int)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--headed", action="store_true", help="Run Chromium with a visible window.")
    return p.parse_args()


def load_targets(dsn, years, start_year=None):
    """
    Pull the crawl list directly from catalog.sets by release year.

    Crawl order:
      1. newest release_year to oldest release_year
      2. highest lego_set_id to lowest lego_set_id within each year
    """
    with psycopg.connect(dsn, options="-c client_encoding=UTF8") as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT max(s.release_year)::integer
                FROM catalog.sets s
                JOIN catalog.items i USING (catalog_item_id)
                WHERE i.item_kind='SET'::catalog.item_kind
                  AND s.lego_set_id BETWEEN 100 AND 99999
                  AND s.release_year IS NOT NULL
                  AND i.status <> 'ARCHIVED'::catalog.item_status
            """)
            latest_year = cur.fetchone()[0]
            if latest_year is None:
                raise RuntimeError(
                    "No catalog.sets rows with lego_set_id and release_year."
                )

            max_year = int(start_year) if start_year is not None else int(latest_year)
            min_year = max_year - years + 1

            cur.execute("""
                SELECT
                    i.catalog_item_id::text,
                    s.lego_set_id::integer,
                    s.release_year::integer,
                    i.canonical_name
                FROM catalog.sets s
                JOIN catalog.items i USING (catalog_item_id)
                WHERE i.item_kind='SET'::catalog.item_kind
                  AND s.lego_set_id BETWEEN 100 AND 99999
                  AND s.release_year BETWEEN %s AND %s
                  AND i.status <> 'ARCHIVED'::catalog.item_status
                ORDER BY
                    s.release_year DESC,
                    s.lego_set_id DESC,
                    i.catalog_item_id
            """, (min_year, max_year))
            rows = cur.fetchall()

    seen = set()
    targets = []
    for catalog_item_id, lego_set_id, release_year, name in rows:
        key = (int(release_year), int(lego_set_id))
        if key in seen:
            continue
        seen.add(key)
        targets.append({
            "catalog_item_id": str(catalog_item_id),
            "set_number": str(int(lego_set_id)),
            "release_year": int(release_year),
            "canonical_name": str(name),
        })

    return int(max_year), min_year, targets


def new_year_doc(year):
    return {
        "schema_version": "1.0",
        "source": "LEGO",
        "release_year": year,
        "generated_at": now(),
        "updated_at": now(),
        "sets": [],
    }


def year_path(outdir, year):
    return outdir / f"lego_instructions_{year}.json"


def load_doc(outdir, year, restart):
    p = year_path(outdir, year)
    if restart or not p.exists():
        return new_year_doc(year)

    try:
        with p.open("r", encoding="utf-8") as f:
            doc = json.load(f)
    except json.JSONDecodeError as exc:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = p.with_name(f"{p.stem}.corrupt-{stamp}{p.suffix}")
        shutil.move(str(p), str(backup))
        print(
            f"[WARN] Corrupt JSON snapshot moved to {backup} "
            f"({exc.msg} at line {exc.lineno} column {exc.colno})"
        )
        return new_year_doc(year)

    if doc.get("schema_version") != "1.0" or int(doc.get("release_year")) != year:
        raise RuntimeError(f"Invalid snapshot file: {p}")

    if not isinstance(doc.get("sets"), list):
        raise RuntimeError(f"Invalid snapshot file: {p}: sets must be an array")

    return doc


def completed(docs, retry_errors):
    done = set()
    for doc in docs.values():
        for row in doc.get("sets", []):
            st = row.get("status")
            if st in TERMINAL or (st == "REQUEST_ERROR" and not retry_errors):
                done.add(str(row.get("set_number")))
    return done


def upsert(doc, result):
    n = str(result["set_number"])
    rows = [r for r in doc["sets"] if str(r.get("set_number")) != n]
    rows.append(result)
    rows.sort(key=lambda r: int(r["set_number"]), reverse=True)
    doc["sets"] = rows
    doc["updated_at"] = now()


def normalize_pdf(page_url, u):
    u = html.unescape(u).replace("\\u002F", "/").replace("\\/", "/")
    return urljoin(page_url, u)


def pdf_id(url):
    m = PDF_ID_RE.search(url)
    if m:
        return m.group(1)
    return Path(urlparse(url).path).stem


def nearby_label(raw, url, name):
    forms = (url, url.replace("/", r"\/"), html.escape(url, quote=True))
    pos = -1
    for form in forms:
        pos = raw.find(form)
        if pos >= 0:
            break
    if pos < 0:
        return None
    window = raw[max(0, pos - 1400):pos + 300]
    plain = clean(re.sub(r"<[^>]+>", " ", html.unescape(window))) or ""
    matches = FRAC_RE.findall(plain)
    if not matches:
        return None
    a, b = matches[-1]
    return f"{name} ({a}/{b})" if name else f"{a}/{b}"


def parse_page(page_url, raw):
    decoded = html.unescape(raw).replace("\\u002F", "/").replace("\\/", "/")
    p = Parser()
    p.feed(raw)

    ym = YEAR_RE.search(p.plain)
    lego_year = int(ym.group(1)) if ym else None

    urls = []
    for href, _ in p.links:
        if ".pdf" in href.lower():
            urls.append(normalize_pdf(page_url, href))
    for m in PDF_RE.finditer(decoded):
        urls.append(normalize_pdf(page_url, m.group("u")))

    unique = []
    seen = set()
    for u in urls:
        if u not in seen:
            seen.add(u)
            unique.append(u)

    instructions = [{
        "instruction_id": pdf_id(u),
        "label": nearby_label(decoded, u, p.h1),
        "pdf_url": u,
        "language": None,
    } for u in unique]

    return p.h1, lego_year, instructions


def is_access_denied(status, body):
    if status in (401, 403):
        return True
    body_l = (body or "").lower()
    markers = (
        "access denied",
        "forbidden",
        "captcha",
        "verify you are human",
        "are you a human",
        "checking your browser",
        "challenge-platform",
    )
    return any(m in body_l for m in markers)


def fetch_with_browser(page, url, timeout):
    try:
        response = page.goto(
            url,
            wait_until="domcontentloaded",
            timeout=timeout * 1000,
        )
    except PlaywrightTimeoutError:
        return None, None, "browser timeout"

    status = response.status if response is not None else None

    # Give client-side content a short opportunity to render.
    try:
        page.wait_for_timeout(1200)
    except Exception:
        pass

    try:
        body = page.content()
    except Exception as exc:
        return status, None, f"page content error: {type(exc).__name__}: {exc}"

    return status, body, None


def crawl_one(page, target, base_url, timeout):
    n = target["set_number"]
    url = f"{base_url.rstrip('/')}/{n}"
    status, body, error = fetch_with_browser(page, url, timeout)

    result = {
        "set_number": n,
        "bricktrackr_catalog_item_id": target["catalog_item_id"],
        "bricktrackr_release_year": target["release_year"],
        "bricktrackr_canonical_name": target["canonical_name"],
        "lego_url": url,
        "found": False,
        "status": None,
        "http_status": status,
        "checked_at": now(),
        "lego_set_name": None,
        "lego_release_year": None,
        "instructions": [],
    }

    if error:
        result["status"] = "REQUEST_ERROR"
        result["error"] = error
        return result

    if is_access_denied(status, body):
        result["status"] = "ACCESS_DENIED"
        result["error"] = f"LEGO access challenge/denial detected (HTTP {status})"
        return result

    if status == 404:
        result["status"] = "NOT_FOUND"
        return result

    if status is None or not (200 <= status < 400):
        result["status"] = "REQUEST_ERROR"
        result["error"] = f"unexpected HTTP status {status}"
        return result

    name, year, inst = parse_page(url, body or "")
    result["found"] = True
    result["lego_set_name"] = name
    result["lego_release_year"] = year
    result["instructions"] = inst
    result["status"] = "FOUND" if inst else "NO_INSTRUCTIONS"
    return result


def save_checkpoint(outdir, max_year, min_year, targets, attempted, skipped, stats, last):
    atomic_json(outdir / "lego_instructions_checkpoint.json", {
        "schema_version": "1.0",
        "crawler_version": VERSION,
        "source": "LEGO",
        "updated_at": now(),
        "latest_release_year": max_year,
        "minimum_release_year": min_year,
        "total_targets": len(targets),
        "attempted_this_run": attempted,
        "skipped_existing_this_run": skipped,
        "stats_this_run": stats,
        "last_attempted": last,
    })


def main():
    a = parse_args()
    if not a.dsn:
        raise SystemExit("[FAIL] Set --dsn or BRICKTRACKR_DATABASE_URL.")
    if not (1 <= a.years <= 50):
        raise SystemExit("[FAIL] --years must be 1..50")
    if a.start_year is not None and not (1900 <= a.start_year <= 2100):
        raise SystemExit("[FAIL] --start-year must be between 1900 and 2100")
    if a.min_delay < 0 or a.max_delay < a.min_delay:
        raise SystemExit("[FAIL] require 0 <= min-delay <= max-delay")

    outdir = a.output_dir.resolve()
    outdir.mkdir(parents=True, exist_ok=True)

    max_year, min_year, targets = load_targets(a.dsn, a.years, a.start_year)

    print(f"[SCOPE] release years {min_year}-{max_year}")
    print(f"[SCOPE] known numeric SETs: {len(targets):,}")
    print("[SCOPE] LEGO ID filter: 100..99,999 (3-5 digits)")
    if targets:
        print(
            f"[SCOPE] first target: year={targets[0]['release_year']} "
            f"LEGO={targets[0]['set_number']}"
        )
        print(
            f"[SCOPE] last target : year={targets[-1]['release_year']} "
            f"LEGO={targets[-1]['set_number']}"
        )

    if a.dry_run:
        counts = {}
        for t in targets:
            counts[t["release_year"]] = counts.get(t["release_year"], 0) + 1
        for y in sorted(counts, reverse=True):
            print(f"[YEAR] {y}: {counts[y]:,}")
        return 0

    docs = {y: load_doc(outdir, y, a.restart)
            for y in range(max_year, min_year - 1, -1)}
    done = set() if a.restart else completed(docs, a.retry_errors)

    attempted = skipped = 0
    stats = {"found": 0, "no_instructions": 0, "not_found": 0, "request_errors": 0}
    last = None

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not a.headed)
        context = browser.new_context(
            user_agent=a.user_agent,
            locale="en-US",
            viewport={"width": 1440, "height": 1000},
        )
        page = context.new_page()

        try:
            for t in targets:
                if t["set_number"] in done:
                    skipped += 1
                    continue
                if a.limit is not None and attempted >= a.limit:
                    break
                if attempted:
                    delay = random.uniform(a.min_delay, a.max_delay)
                    print(f"[WAIT] {delay:.1f}s")
                    time.sleep(delay)

                print(f"[GET] {t['set_number']} year={t['release_year']} {t['canonical_name']}")
                r = crawl_one(page, t, a.base_url, a.timeout)
                attempted += 1
                last = {
                    "set_number": t["set_number"],
                    "release_year": t["release_year"],
                    "catalog_item_id": t["catalog_item_id"],
                }

                if r["status"] == "FOUND":
                    stats["found"] += 1
                    print(f"[FOUND] {t['set_number']}: {len(r['instructions'])} PDF(s)")
                elif r["status"] == "NO_INSTRUCTIONS":
                    stats["no_instructions"] += 1
                    print(f"[EMPTY] {t['set_number']}")
                elif r["status"] == "NOT_FOUND":
                    stats["not_found"] += 1
                    print(f"[404] {t['set_number']}")
                elif r["status"] == "ACCESS_DENIED":
                    stats["request_errors"] += 1
                    print(f"[ACCESS DENIED] {t['set_number']}: {r.get('error')}", file=sys.stderr)
                else:
                    stats["request_errors"] += 1
                    print(f"[ERROR] {t['set_number']}: {r.get('error')}", file=sys.stderr)

                upsert(docs[t["release_year"]], r)
                atomic_json(year_path(outdir, t["release_year"]), docs[t["release_year"]])
                save_checkpoint(outdir, max_year, min_year, targets, attempted, skipped, stats, last)
                if r["status"] == "ACCESS_DENIED":
                    print("[STOP] LEGO access challenge detected. Checkpoint saved; stopping crawl.")
                    break

        except KeyboardInterrupt:
            save_checkpoint(outdir, max_year, min_year, targets, attempted, skipped, stats, last)
            print("\n[INTERRUPTED] Checkpoint saved. Rerun to resume.")
            context.close()
            browser.close()
            return 130
        finally:
            try:
                context.close()
            except Exception:
                pass
            try:
                browser.close()
            except Exception:
                pass

    save_checkpoint(outdir, max_year, min_year, targets, attempted, skipped, stats, last)
    print("[PASS] crawl finished")
    print(f" attempted={attempted:,} skipped={skipped:,} stats={stats}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
