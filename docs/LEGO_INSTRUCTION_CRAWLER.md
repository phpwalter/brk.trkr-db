# BrickTrackr LEGO Instruction Crawler

## What it does

- queries BrickTrackr first;
- uses only known numeric `catalog.sets.lego_set_id` values;
- uses the latest `release_year` in BrickTrackr and scans the latest 10 release years;
- orders by LEGO set ID descending;
- requests LEGO every randomized 3-5 seconds;
- stores PDF URLs only;
- stores one JSON file per year;
- records `FOUND`, `NO_INSTRUCTIONS`, `NOT_FOUND`, and `REQUEST_ERROR`;
- writes a checkpoint after every attempt;
- resumes automatically when rerun.

## Dependencies

```powershell
uv sync
```

## Database connection

```powershell
$env:BRICKTRACKR_DATABASE_URL = "postgresql://root:PASSWORD@HOST:5432/bricktrackr"
```

Run this as the BrickTrackr owner/root maintenance identity because it reads canonical tables directly.

## Dry run

```powershell
python .\tools\lego_instruction_crawler.py --dry-run
```

## Five-set test

```powershell
python .\tools\lego_instruction_crawler.py --limit 5
```

## Full crawl

```powershell
python .\tools\lego_instruction_crawler.py
```

## Resume

Run the same command again.

Retry previously recorded request errors:

```powershell
python .\tools\lego_instruction_crawler.py --retry-errors
```

Restart all selected years:

```powershell
python .\tools\lego_instruction_crawler.py --restart
```

Default output:

```text
data/lego-instructions/
    lego_instructions_2026.json
    lego_instructions_2025.json
    ...
    lego_instructions_checkpoint.json
```

Each instruction contains `instruction_id`, `label`, `pdf_url`, and `language`.
The crawler does not download PDFs and does not assume PDF count equals physical booklet count.


## v1.1 fix

- Filters `catalog.sets.lego_set_id` to `100..9,999,999` so unrelated large numeric identifiers are not requested from LEGO.
- Fixes the atomic JSON writer newline mode.
- Keeps the 3-5 second delay, yearly JSON files, and checkpoint/resume behavior.


## v1.2 year-driven crawl

The crawl list now comes directly from `catalog.sets` and is ordered by
`release_year DESC, lego_set_id DESC`. The crawler finishes the newest release
year before moving to the prior year.


## v1.3 optional start year

Use the latest BrickTrackr release year by default:

```powershell
python .\tools\lego_instruction_crawler.py
```

Or explicitly choose the top year:

```powershell
python .\tools\lego_instruction_crawler.py --start-year 2025 --years 10
```

That crawls release years 2025 down through 2016.


## v1.4 five-digit LEGO set limit

Only numeric LEGO set IDs from `100` through `99,999` are included.

This excludes all 6+ digit values before the crawl list is built.


## v1.5 corrupt JSON recovery

If an existing yearly JSON snapshot cannot be parsed, the crawler no longer
aborts. It renames the bad file to:

```text
lego_instructions_YYYY.corrupt-YYYYMMDDTHHMMSSZ.json
```

and starts a clean snapshot for that year.

This preserves the damaged file for inspection while allowing the crawl to continue.


## v1.6 Playwright browser crawler

The LEGO fetch path now uses Playwright/Chromium instead of `requests`.

Install dependencies:

```powershell
uv sync
uv run playwright install chromium
```

Run normally:

```powershell
python .\tools\lego_instruction_crawler.py `
  --dsn "postgresql://root:root@127.0.0.1:5432/bricktrackr" `
  --start-year 2025 `
  --years 2
```

For troubleshooting, show the browser window:

```powershell
python .\tools\lego_instruction_crawler.py `
  --dsn "postgresql://root:root@127.0.0.1:5432/bricktrackr" `
  --start-year 2025 `
  --years 2 `
  --headed
```

If LEGO presents an access-denied/CAPTCHA/challenge page, the crawler records
`ACCESS_DENIED`, saves the yearly JSON/checkpoint, and stops. It does not attempt
to bypass the challenge.
