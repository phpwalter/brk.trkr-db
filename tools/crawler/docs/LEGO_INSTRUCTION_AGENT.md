# BrickTrackr LEGO Instruction Agent v1.8

## What changed

The old parser counted every PDF URL found in rendered/embedded page data.
That over-counted LEGO instruction books.

Parser v2 now counts **logical visible instruction booklets**:

- only visible rendered PDF anchors are considered;
- a visible `(n/m)` booklet marker is required;
- all PDF variants for the same `(n/m)` are grouped together;
- one canonical `INSTRUCTIONS` item is created per logical booklet;
- all observed PDF variants remain preserved in JSON.

Example:

```json
{
  "instruction_id": "77250:booklet:1-of-1",
  "booklet_number": 1,
  "booklet_count": 1,
  "label": "1/1",
  "document_id": "example",
  "pdf_url": "https://...",
  "pdf_variants": ["https://..."],
  "language": null
}
```

## Existing JSON

Rows produced by older parsers do not contain:

```json
"parser_version": "2.0-visible-booklets"
```

They are automatically eligible for re-crawl. Parser-v2 results replace the
old SET record in that year's JSON file.

Database sync ignores all legacy parser records.

## Database correction

Apply the updated reconciler:

```powershell
psql -U root -d bricktrackr -v ON_ERROR_STOP=1 `
  -f .\tools\crawler\sql\5031_importer_lego_instructions_hotfix.sql
```

Optional but recommended before resuming: immediately quarantine all current
LEGO instruction manifest links created by the old parser:

```powershell
psql -U root -d bricktrackr -v ON_ERROR_STOP=1 `
  -f .\tools\crawler\sql\5032_quarantine_legacy_lego_instruction_links.sql
```

This is a soft cleanup only:

```text
definition.set_manifest_components.source_present = false
```

No catalog rows are hard-deleted and no catalog lifecycle state is changed.

As parser-v2 results are imported, valid SET → INSTRUCTIONS links are reasserted.

## Verify

```powershell
psql -U root -d bricktrackr -v ON_ERROR_STOP=1 `
  -f .\tools\crawler\sql\verify_lego_instruction_importer.sql
```

## Validation crawl

```powershell
python .\tools\crawler\lego_instruction_crawler.py `
  --start-year 2025 `
  --years 1 `
  --limit 10 `
  --once `
  --headed
```

You should now see output such as:

```text
[FOUND] 77250: 1 booklet(s)
```

rather than four PDF assets.

## Continuous run

```powershell
python .\tools\crawler\lego_instruction_crawler.py `
  --start-year 2025 `
  --years 10
```

The existing agent schedule remains:

```text
crawl <= 2 hours
→ DB sync
→ wait 3 hours
→ DB sync
→ repeat
```


## v1.8.1 diagnostic and accessory filtering

Exact-set diagnostic mode:

```powershell
python .\tools\crawler\lego_instruction_crawler.py `
  --set-number 77250 `
  --limit 1 `
  --once `
  --headed
```

When `--set-number` is supplied, the year window is ignored and that exact
`catalog.sets.lego_set_id` is tested.

Normal year-based crawling now skips a conservative list of obvious standalone
accessory rows such as `Rechargeable Battery`, battery boxes, hubs, standalone
motors, and sensors. Use `--include-nonbuildable` to disable that filter.

A known BrickTrackr SET that returns HTTP 404, or a legitimate LEGO page that
renders without any visible `(n/m)` instruction-booklet cards, is recorded as:

```text
NO_INSTRUCTION_PAGE
```

A real HTTP 403/CAPTCHA/challenge remains:

```text
ACCESS_DENIED
```

`NO_INSTRUCTION_PAGE` is terminal and is never submitted to the database.
