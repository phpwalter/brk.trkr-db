#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

import psycopg
from psycopg.types.json import Jsonb
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError

VERSION = "1.8.1"
PARSER_VERSION = "2.0-visible-booklets"

BASE_URL = "https://www.lego.com/en-us/service/building-instructions"
DEFAULT_READ_DSN = "postgresql://root:root@127.0.0.1:5432/bricktrackr"
DEFAULT_IMPORT_DSN = "postgresql://bricktrackr_import:import@127.0.0.1:5432/bricktrackr"

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "data" / "lego-instructions"

TERMINAL = {"FOUND", "NO_INSTRUCTIONS", "NO_INSTRUCTION_PAGE", "NOT_FOUND"}


def now_dt():
    return datetime.now(timezone.utc)


def now_iso():
    return now_dt().isoformat()


def atomic_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def parse_args():
    p = argparse.ArgumentParser(description="BrickTrackr LEGO instruction crawler/agent.")
    p.add_argument("--dsn", default=DEFAULT_READ_DSN)
    p.add_argument("--import-dsn", default=DEFAULT_IMPORT_DSN)
    p.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    p.add_argument("--start-year", type=int, default=None)
    p.add_argument("--set-number", type=int, default=None, help="Diagnostic mode: crawl exactly one known LEGO set number.")
    p.add_argument("--include-nonbuildable", action="store_true", help="Include obvious battery/hub/motor accessory rows normally skipped by the crawler.")
    p.add_argument("--years", type=int, default=10)
    p.add_argument("--crawl-hours", type=float, default=2.0)
    p.add_argument("--rest-hours", type=float, default=3.0)
    p.add_argument("--db-retry-minutes", type=float, default=15.0)
    p.add_argument("--batch-size", type=int, default=100)
    p.add_argument("--timeout", type=int, default=60)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--headed", action="store_true")
    p.add_argument("--once", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--retry-errors", action="store_true")
    p.add_argument("--no-db-sync", action="store_true")
    return p.parse_args()


def is_obvious_nonbuildable(name):
    """
    Conservative accessory filter. Only names that are essentially standalone
    electronic/accessory products are skipped. Normal buildable SET names are
    not excluded merely because they contain words such as "motor".
    """
    value = (name or "").strip().lower()
    patterns = (
        r"^rechargeable battery$",
        r"^battery box$",
        r"^powered up hub$",
        r"^technic hub$",
        r"^large hub$",
        r"^move hub$",
        r"^train motor$",
        r"^large angular motor$",
        r"^medium angular motor$",
        r"^color sensor$",
        r"^distance sensor$",
    )
    return any(re.fullmatch(pattern, value) for pattern in patterns)


def load_targets(dsn, years, start_year, set_number=None, include_nonbuildable=False):
    with psycopg.connect(dsn) as conn, conn.cursor() as cur:
        if set_number is not None:
            if not 100 <= int(set_number) <= 99999:
                raise RuntimeError("--set-number must be between 100 and 99,999")

            cur.execute("""
                SELECT i.catalog_item_id::text,
                       s.lego_set_id::int,
                       s.release_year::int,
                       i.canonical_name
                FROM catalog.sets s
                JOIN catalog.items i USING (catalog_item_id)
                WHERE i.item_kind='SET'::catalog.item_kind
                  AND s.lego_set_id = %s
                  AND i.status <> 'ARCHIVED'::catalog.item_status
                ORDER BY
                    CASE WHEN i.status='ACTIVE'::catalog.item_status THEN 0 ELSE 1 END,
                    s.release_year DESC,
                    i.catalog_item_id
                LIMIT 1
            """, (int(set_number),))
            row = cur.fetchone()
            if row is None:
                raise RuntimeError(
                    f"LEGO set {set_number} was not found in catalog.sets"
                )

            catalog_item_id, lego_set_id, release_year, name = row
            target = {
                "catalog_item_id": catalog_item_id,
                "set_number": str(lego_set_id),
                "release_year": release_year,
                "canonical_name": name,
            }
            return release_year, release_year, [target]

        cur.execute("""
            SELECT max(s.release_year)::int
            FROM catalog.sets s
            JOIN catalog.items i USING (catalog_item_id)
            WHERE i.item_kind='SET'::catalog.item_kind
              AND s.lego_set_id BETWEEN 100 AND 99999
              AND s.release_year IS NOT NULL
              AND i.status <> 'ARCHIVED'::catalog.item_status
        """)
        latest = cur.fetchone()[0]
        if latest is None:
            raise RuntimeError("No eligible catalog.sets rows found.")

        max_year = int(start_year) if start_year is not None else int(latest)
        min_year = max_year - int(years) + 1

        cur.execute("""
            SELECT i.catalog_item_id::text,
                   s.lego_set_id::int,
                   s.release_year::int,
                   i.canonical_name
            FROM catalog.sets s
            JOIN catalog.items i USING (catalog_item_id)
            WHERE i.item_kind='SET'::catalog.item_kind
              AND s.lego_set_id BETWEEN 100 AND 99999
              AND s.release_year BETWEEN %s AND %s
              AND i.status <> 'ARCHIVED'::catalog.item_status
            ORDER BY s.release_year DESC, s.lego_set_id DESC, i.catalog_item_id
        """, (min_year, max_year))
        rows = cur.fetchall()

    seen = set()
    targets = []
    for catalog_item_id, lego_set_id, release_year, name in rows:
        key = (release_year, lego_set_id)
        if key in seen:
            continue
        seen.add(key)

        if not include_nonbuildable and is_obvious_nonbuildable(name):
            continue

        targets.append({
            "catalog_item_id": catalog_item_id,
            "set_number": str(lego_set_id),
            "release_year": release_year,
            "canonical_name": name,
        })
    return max_year, min_year, targets


def year_file(outdir, year):
    return outdir / f"lego_instructions_{year}.json"


def new_year_doc(year):
    return {
        "schema_version": "1.1",
        "parser_version": PARSER_VERSION,
        "source": "LEGO",
        "release_year": year,
        "generated_at": now_iso(),
        "updated_at": now_iso(),
        "sets": [],
    }


def load_year_doc(outdir, year):
    path = year_file(outdir, year)
    if not path.exists():
        return new_year_doc(year)
    try:
        with path.open("r", encoding="utf-8") as f:
            doc = json.load(f)
    except json.JSONDecodeError as exc:
        stamp = now_dt().strftime("%Y%m%dT%H%M%SZ")
        backup = path.with_name(f"{path.stem}.corrupt-{stamp}{path.suffix}")
        shutil.move(str(path), str(backup))
        print(f"[WARN] corrupt JSON moved to {backup}: {exc}")
        return new_year_doc(year)

    if not isinstance(doc.get("sets"), list):
        raise RuntimeError(f"{path}: sets is not an array")
    return doc


def completed_set_numbers(docs, retry_errors):
    done = set()
    for doc in docs.values():
        for row in doc.get("sets", []):
            # Legacy parser rows are deliberately NOT complete.
            if row.get("parser_version") != PARSER_VERSION:
                continue
            status = row.get("status")
            if status in TERMINAL:
                done.add(str(row.get("set_number")))
            elif status == "REQUEST_ERROR" and not retry_errors:
                done.add(str(row.get("set_number")))
    return done


def upsert_result(doc, result):
    n = result["set_number"]
    rows = [r for r in doc["sets"] if str(r.get("set_number")) != n]
    rows.append(result)
    rows.sort(key=lambda r: int(r["set_number"]), reverse=True)
    doc["sets"] = rows
    doc["parser_version"] = PARSER_VERSION
    doc["updated_at"] = now_iso()


def is_access_denied(status, html):
    if status in (401, 403):
        return True
    body = (html or "").lower()
    return any(x in body for x in (
        "access denied", "captcha", "verify you are human",
        "checking your browser", "challenge-platform"
    ))


def pdf_document_id(url):
    stem = Path(urlparse(url).path).stem
    return stem or url


def extract_visible_booklets(page, set_number):
    """
    Only visible PDF anchors count. Nearby visible card text must contain (n/m).
    Multiple PDF variants with the same logical booklet fraction collapse to one
    canonical booklet.
    """
    candidates = page.locator('a[href*=".pdf"]').evaluate_all(r"""
        els => els
          .filter(el => {
            const r = el.getBoundingClientRect();
            const s = getComputedStyle(el);
            return r.width > 0 && r.height > 0 &&
                   s.display !== 'none' && s.visibility !== 'hidden';
          })
          .map(el => {
            let node = el;
            let context = '';
            for (let i = 0; i < 8 && node; i++, node = node.parentElement) {
              const t = (node.innerText || '').replace(/\s+/g, ' ').trim();
              if (t) context = t;
              if (/\(\s*\d+\s*\/\s*\d+\s*\)/.test(context)) break;
            }
            return {href: el.href, context};
          });
    """)

    fraction_re = re.compile(r"\(\s*(\d+)\s*/\s*(\d+)\s*\)")
    grouped = {}

    for c in candidates:
        url = (c.get("href") or "").strip()
        context = c.get("context") or ""
        if not url or ".pdf" not in url.lower():
            continue
        m = fraction_re.search(context)
        if not m:
            continue
        current, total = int(m.group(1)), int(m.group(2))
        if current < 1 or total < 1 or current > total:
            continue

        key = (current, total)
        grouped.setdefault(key, [])
        if url not in grouped[key]:
            grouped[key].append(url)

    rows = []
    for (current, total), urls in sorted(grouped.items()):
        primary = urls[0]
        rows.append({
            "instruction_id": f"{set_number}:booklet:{current}-of-{total}",
            "booklet_number": current,
            "booklet_count": total,
            "label": f"{current}/{total}",
            "document_id": pdf_document_id(primary),
            "pdf_url": primary,
            "pdf_variants": urls,
            "language": None,
        })
    return rows


def crawl_one(page, target, timeout):
    n = target["set_number"]
    url = f"{BASE_URL}/{n}"

    try:
        response = page.goto(url, wait_until="domcontentloaded", timeout=timeout * 1000)
    except PlaywrightTimeoutError:
        return {
            "set_number": n,
            "bricktrackr_release_year": target["release_year"],
            "bricktrackr_canonical_name": target["canonical_name"],
            "lego_url": url,
            "found": False,
            "status": "REQUEST_ERROR",
            "error": "browser timeout",
            "checked_at": now_iso(),
            "parser_version": PARSER_VERSION,
            "instructions": [],
        }

    status = response.status if response else None
    page.wait_for_timeout(2500)
    html = page.content()

    base = {
        "set_number": n,
        "bricktrackr_release_year": target["release_year"],
        "bricktrackr_canonical_name": target["canonical_name"],
        "lego_url": url,
        "found": False,
        "status": None,
        "http_status": status,
        "checked_at": now_iso(),
        "parser_version": PARSER_VERSION,
        "instructions": [],
    }

    if is_access_denied(status, html):
        base["status"] = "ACCESS_DENIED"
        return base
    if status == 404:
        base["status"] = "NO_INSTRUCTION_PAGE"
        return base
    if status is None or not 200 <= status < 400:
        base["status"] = "REQUEST_ERROR"
        base["error"] = f"unexpected HTTP status {status}"
        return base

    instructions = extract_visible_booklets(page, n)
    base["found"] = True
    base["instructions"] = instructions
    if instructions:
        base["status"] = "FOUND"
    else:
        base["status"] = "NO_INSTRUCTION_PAGE"
    return base


def weighted_delay():
    roll = random.random()
    if roll < 0.80:
        return random.uniform(8, 60)
    if roll < 0.95:
        return random.uniform(60, 300)
    return random.uniform(300, 900)


def source_records_for_db(outdir):
    rows = []
    for path in sorted(outdir.glob("lego_instructions_[0-9][0-9][0-9][0-9].json")):
        with path.open("r", encoding="utf-8") as f:
            doc = json.load(f)
        for row in doc.get("sets", []):
            if row.get("parser_version") != PARSER_VERSION:
                continue
            if row.get("status") != "FOUND" or not row.get("instructions"):
                continue
            rows.append({
                "set_number": row["set_number"],
                "release_year": row.get("bricktrackr_release_year"),
                "canonical_name": row.get("bricktrackr_canonical_name"),
                "lego_url": row.get("lego_url"),
                "checked_at": row.get("checked_at"),
                "parser_version": row.get("parser_version"),
                "instructions": row.get("instructions", []),
            })
    rows.sort(key=lambda r: (int(r.get("release_year") or 0), int(r["set_number"])), reverse=True)
    return rows


def scalar(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        row = cur.fetchone()
        return row[0] if row else None


def sync_database(import_dsn, outdir, batch_size):
    rows = source_records_for_db(outdir)
    print(f"[DB] parser-v2 FOUND sets available for sync: {len(rows):,}")
    if not rows:
        return True

    try:
        with psycopg.connect(import_dsn, autocommit=True) as conn:
            run_id = scalar(
                conn,
                "SELECT import.begin_lego_instruction_sync(%s::jsonb)",
                (Jsonb({"agent_version": VERSION, "parser_version": PARSER_VERSION}),),
            )
            totals = {}
            for offset in range(0, len(rows), batch_size):
                batch = rows[offset:offset + batch_size]
                result = scalar(
                    conn,
                    "SELECT import.reconcile_lego_instruction_batch(%s::uuid,%s::jsonb)",
                    (run_id, Jsonb(batch)),
                ) or {}
                print(f"[DB] batch {offset+1}-{offset+len(batch)}: {result}")
                for k, v in result.items():
                    if isinstance(v, int):
                        totals[k] = totals.get(k, 0) + v

            done = scalar(
                conn,
                "SELECT import.complete_lego_instruction_sync(%s::uuid,%s::jsonb)",
                (run_id, Jsonb(totals)),
            )
            print(f"[DB PASS] {done}")
            return True
    except Exception as exc:
        print(f"[DB ERROR] {type(exc).__name__}: {exc}", file=sys.stderr)
        return False


def state_file(outdir):
    return outdir / "lego_instruction_agent_state.json"


def save_state(outdir, phase, **extra):
    data = {"phase": phase, "updated_at": now_iso(), "agent_version": VERSION}
    data.update(extra)
    atomic_json(state_file(outdir), data)


def load_state(outdir):
    p = state_file(outdir)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def run_crawl_cycle(a, outdir):
    max_year, min_year, targets = load_targets(a.dsn, a.years, a.start_year, a.set_number, a.include_nonbuildable)
    docs = {y: load_year_doc(outdir, y) for y in range(max_year, min_year - 1, -1)}
    done = completed_set_numbers(docs, a.retry_errors)

    print("=" * 78)
    print(f" BrickTrackr LEGO Instruction Agent v{VERSION}")
    print("=" * 78)
    print(f"[SCOPE] release years: {min_year}-{max_year}")
    print(f"[SCOPE] known SETs   : {len(targets):,}")
    print("[SCOPE] LEGO IDs     : 100..99,999")
    print(f"[SCOPE] non-buildable accessory filter: {'OFF' if a.include_nonbuildable or a.set_number is not None else 'ON'}")
    if targets:
        print(f"[SCOPE] first target : year={targets[0]['release_year']} LEGO={targets[0]['set_number']}")
        print(f"[SCOPE] last target  : year={targets[-1]['release_year']} LEGO={targets[-1]['set_number']}")

    if a.dry_run:
        return

    deadline = now_dt() + timedelta(hours=a.crawl_hours)
    save_state(outdir, "CRAWL", crawl_deadline=deadline.isoformat())

    attempted = 0
    skipped = 0

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not a.headed)
        context = browser.new_context(locale="en-US", viewport={"width": 1440, "height": 1000})
        page = context.new_page()
        first = True
        try:
            for target in targets:
                if target["set_number"] in done:
                    skipped += 1
                    continue
                if a.limit is not None and attempted >= a.limit:
                    print(f"[CYCLE] request limit {a.limit} reached")
                    break
                if now_dt() >= deadline:
                    print("[CYCLE] crawl window reached")
                    break

                if not first:
                    delay = weighted_delay()
                    if now_dt() + timedelta(seconds=delay) >= deadline:
                        print("[CYCLE] sampled wait would exceed crawl window")
                        break
                    print(f"[WAIT] {delay:.1f}s")
                    time.sleep(delay)
                first = False

                print(f"[GET] {target['set_number']} year={target['release_year']} {target['canonical_name']}")
                result = crawl_one(page, target, a.timeout)
                attempted += 1

                if result["status"] == "FOUND":
                    print(f"[FOUND] {target['set_number']}: {len(result['instructions'])} booklet(s)")
                elif result["status"] == "NO_INSTRUCTIONS":
                    print(f"[EMPTY] {target['set_number']}")
                elif result["status"] == "ACCESS_DENIED":
                    print(f"[ACCESS DENIED] {target['set_number']}")
                elif result["status"] == "NO_INSTRUCTION_PAGE":
                    print(f"[NO INSTRUCTION PAGE] {target['set_number']}")
                elif result["status"] == "NOT_FOUND":
                    print(f"[404] {target['set_number']}")
                else:
                    print(f"[ERROR] {target['set_number']}: {result.get('error')}")

                doc = docs[target["release_year"]]
                upsert_result(doc, result)
                atomic_json(year_file(outdir, target["release_year"]), doc)

                if result["status"] == "ACCESS_DENIED":
                    print("[STOP] challenge/access denial detected; ending crawl cycle")
                    break
        finally:
            context.close()
            browser.close()

    print(f"[CYCLE] crawl complete: attempted={attempted:,} skipped={skipped:,}")


def rest_phase(a, outdir, next_cycle_at, initial_sync_ok):
    save_state(outdir, "WAIT", next_cycle_at=next_cycle_at.isoformat())
    sync_ok = initial_sync_ok
    next_retry = now_dt() + timedelta(minutes=a.db_retry_minutes)

    while now_dt() < next_cycle_at:
        if not a.no_db_sync and not sync_ok and now_dt() >= next_retry:
            sync_ok = sync_database(a.import_dsn, outdir, a.batch_size)
            next_retry = now_dt() + timedelta(minutes=a.db_retry_minutes)
        time.sleep(min(60, max(1, (next_cycle_at - now_dt()).total_seconds())))

    if not a.no_db_sync:
        print("[DB] pre-cycle synchronization")
        sync_database(a.import_dsn, outdir, a.batch_size)


def main():
    a = parse_args()
    outdir = a.output_dir.resolve()
    outdir.mkdir(parents=True, exist_ok=True)

    if a.dry_run:
        run_crawl_cycle(a, outdir)
        return 0

    state = load_state(outdir)
    if state and state.get("phase") == "WAIT" and not a.once:
        try:
            next_cycle = datetime.fromisoformat(state["next_cycle_at"])
        except Exception:
            next_cycle = None
        if next_cycle and next_cycle > now_dt():
            print(f"[RESUME] waiting until {next_cycle.isoformat()}")
            initial = True if a.no_db_sync else sync_database(a.import_dsn, outdir, a.batch_size)
            rest_phase(a, outdir, next_cycle, initial)

    while True:
        run_crawl_cycle(a, outdir)

        sync_ok = True
        if not a.no_db_sync:
            print("[DB] post-crawl synchronization")
            sync_ok = sync_database(a.import_dsn, outdir, a.batch_size)

        if a.once:
            save_state(outdir, "STOPPED")
            return 0

        next_cycle = now_dt() + timedelta(hours=a.rest_hours)
        print(f"[REST] next crawl at {next_cycle.isoformat()}")
        rest_phase(a, outdir, next_cycle, sync_ok)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[INTERRUPTED] source JSON preserved")
        raise SystemExit(130)
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
