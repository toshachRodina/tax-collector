# Feature Spec 003 — Folder Scanner (Bindump Processor)

**Status**: Draft
**Created**: 2026-03-24
**Depends on**: 001-database-schema
**Blocks**: None (parallel to 002, 004)

---

## 1. Overview

A pipeline that watches a drop-zone folder (`bindump`) on the Linux server, classifies each file dropped into it using a local LLM (Ollama on Mac Mini), files it into an organised folder structure by financial year and document type, records its metadata in the database, and — for utility bills and structured receipts — extracts line-item data into a flexible database table for longitudinal analysis.

**Core rule: files are NEVER deleted. Every move is an archive operation.**

---

## 2. Folder Paths

The X: drive on the Windows dev machine maps to `/data` on the Ubuntu server (`192.168.0.250`).

| Windows path | Linux path | Purpose |
|---|---|---|
| `X:\data\tax-collector\` | `/data/tax-collector/` | Root |
| `X:\data\tax-collector\bindump\` | `/data/tax-collector/bindump/` | Drop zone — user puts files here |
| `X:\data\tax-collector\YYYY-YYYY\` | `/data/tax-collector/YYYY-YYYY/` | Financial year archive |

---

## 3. Financial Year Folder Naming

Folders are named `YYYY-YYYY` where the first year is the July 1 start year.

| Tax year | Folder name | Dates |
|---|---|---|
| FY2025 | `2024-2025` | Jul 1 2024 – Jun 30 2025 |
| FY2026 | `2025-2026` | Jul 1 2025 – Jun 30 2026 |
| FY2027 | `2026-2027` | Jul 1 2026 – Jun 30 2027 |

The pipeline creates the FY folder automatically if it does not exist. Existing folders (already created for future years) must not be overwritten.

---

## 4. Sub-folder Structure (within each FY folder)

Standard personal tax document taxonomy, numbered for sort order:

```
YYYY-YYYY/
├── 01-income/
│   ├── payslips/
│   ├── bank-interest/
│   ├── dividends/
│   └── other-income/
├── 02-deductions/
│   ├── work-from-home/
│   │   ├── utilities/      ← electricity, gas, water bills (WFH deductible portion)
│   │   └── internet/
│   ├── technology/         ← hardware, software receipts
│   ├── professional-dev/   ← courses, certifications
│   ├── insurance/          ← income protection
│   └── other-deductions/
├── 03-investments/
│   ├── share-trades/       ← broker trade confirmations
│   └── cgt-events/         ← CGT event documents
├── 04-superannuation/
├── 05-health/              ← PHI statements
├── 06-government/
│   ├── ato-notices/
│   └── hecs-help/
├── 07-property/            ← rental income, depreciation schedules
├── 08-receipts-bills/
│   ├── utilities/          ← power, gas, water, internet bills (non-WFH)
│   ├── insurance/
│   └── other/
└── 09-bank-statements/     ← any bank statement PDFs (CSV ingestion is separate)
```

This maps 1:1 to the `ref.tax_categories` table. The classification step determines which sub-folder a file lands in.

---

## 5. Classification Logic

### 5.1 Classifier

Use Ollama on the Mac Mini (`192.168.0.93:11434`). Model: `llama3.2` (text) or `llava` (vision, for image/scanned PDFs).

The classifier receives:
- File name
- File extension
- First 1000 characters of extracted text (PDFs: use `pdfplumber`; images: skip text extraction, use vision model)
- A structured prompt asking it to return JSON

### 5.2 Classification Prompt (template)

```
You are a document classifier for Australian personal tax records.

Classify the following document into one of these categories:
- payslip
- bank-interest
- dividend
- share-trade
- cgt-event
- work-from-home-utility
- work-from-home-internet
- technology-receipt
- professional-development
- insurance-income-protection
- ato-notice
- hecs-help
- superannuation
- health-insurance
- property-income
- property-depreciation
- utility-bill
- insurance-other
- bank-statement
- other

Also determine:
- fy_year: the Australian financial year this document most likely belongs to (e.g. 2025)
  Financial year = July 1 to June 30. If a document is from March 2025, it belongs to FY2025.
  If unclear, return null.
- provider: the company or institution that issued the document (e.g. "AGL", "NAB", "ATO")
- is_deductible: true/false — whether any portion is likely tax-deductible
- confidence: 0.0 to 1.0

File name: {file_name}
Text content (first 1000 chars):
{text_preview}

Respond ONLY with valid JSON:
{
  "category": "...",
  "fy_year": 2025,
  "provider": "...",
  "is_deductible": true,
  "confidence": 0.85
}
```

### 5.3 Category → Folder Mapping

| Category | Target path within FY folder |
|---|---|
| `payslip` | `01-income/payslips/` |
| `bank-interest` | `01-income/bank-interest/` |
| `dividend` | `01-income/dividends/` |
| `share-trade` | `03-investments/share-trades/` |
| `cgt-event` | `03-investments/cgt-events/` |
| `work-from-home-utility` | `02-deductions/work-from-home/utilities/` |
| `work-from-home-internet` | `02-deductions/work-from-home/internet/` |
| `technology-receipt` | `02-deductions/technology/` |
| `professional-development` | `02-deductions/professional-dev/` |
| `insurance-income-protection` | `02-deductions/insurance/` |
| `ato-notice` | `06-government/ato-notices/` |
| `hecs-help` | `06-government/hecs-help/` |
| `superannuation` | `04-superannuation/` |
| `health-insurance` | `05-health/` |
| `property-income` | `07-property/` |
| `property-depreciation` | `07-property/` |
| `utility-bill` | `08-receipts-bills/utilities/` |
| `insurance-other` | `08-receipts-bills/insurance/` |
| `bank-statement` | `09-bank-statements/` |
| `other` | `08-receipts-bills/other/` |

### 5.4 Low Confidence Fallback

If `confidence < 0.6`: file in `08-receipts-bills/other/` and set `review_status = 'NEEDS_REVIEW'` in `core.tax_documents`.

---

## 6. File Move Rules (SAFETY CRITICAL)

```
NEVER delete a source file.
NEVER overwrite a destination file.
```

Steps:
1. **Check destination exists.** Create target directory tree if missing.
2. **Check for filename collision.** If `target/file.pdf` already exists, append a timestamp suffix: `file_20250324_143022.pdf`.
3. **Move** (not copy — removes from bindump after successful move).
4. **Verify** destination file exists and size matches before considering success.
5. If any step fails, leave the file in bindump and log the error. Do not retry automatically — flag for manual review.

---

## 7. Database Recording

For every processed file:

### 7.1 Landing record
Insert into `landing.tax_documents`:
- `source_type = 'FOLDER'`
- `source_id` = absolute Linux path of the **destination** file (after move)
- `subject` = file name (original, before rename)
- `file_name`, `file_ext`, `file_size_bytes`
- `content_preview` = first 500 chars of extracted text
- `raw_json` = `{"original_path": "...", "destination_path": "...", "classifier_response": {...}}`

### 7.2 Core record (via stored proc)
`sp_merge_tax_documents` merges landing → core, dedup on `(source_type, source_id)`.

Fields populated:
- `fy_year` from classifier response
- `tax_category_id` — mapped from classifier category to `ref.tax_categories.category_id`
- `is_deductible`, `confidence_score`, `classification_model`
- `review_status = 'PENDING'` (default) or `'NEEDS_REVIEW'` if confidence < 0.6

---

## 8. Bill Line-Item Extraction (Lower Priority — Phase 2)

For utility bills, insurance statements, and structured receipts, extract itemised data for longitudinal analysis (e.g. track kWh usage over time, rate changes by provider).

### 8.1 New Table: `core.bill_details`

This requires a schema migration (see Section 12 — Migration).

```sql
CREATE TABLE core.bill_details (
    bill_id             SERIAL PRIMARY KEY,
    doc_id              INTEGER NOT NULL REFERENCES core.tax_documents(doc_id),
    provider_nme        VARCHAR(100) NOT NULL,      -- e.g. 'AGL', 'Origin Energy', 'Telstra'
    account_number      VARCHAR(100),
    billing_period_start DATE,
    billing_period_end   DATE,
    total_amount        NUMERIC(10,2),
    line_items          JSONB NOT NULL DEFAULT '[]',
    -- JSONB structure (flexible per provider):
    -- For electricity: [{"label": "Peak usage", "kwh": 320, "rate_cents": 28.5, "amount": 91.20}, ...]
    -- For internet: [{"label": "Monthly plan", "amount": 79.00}, ...]
    -- For insurance: [{"label": "Income protection premium", "amount": 156.00, "period": "monthly"}]
    extracted_by        VARCHAR(50),                -- 'ollama-llava', 'pdfplumber+llm', 'manual'
    extraction_confidence NUMERIC(4,3),
    needs_review        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_bill_details_doc ON core.bill_details(doc_id);
CREATE INDEX idx_bill_details_provider ON core.bill_details(provider_nme, billing_period_start);
COMMENT ON TABLE core.bill_details IS
    'Itemised bill data extracted from utility/insurance/receipt documents. '
    'line_items JSONB is flexible per provider — no fixed schema for line-level detail.';
```

### 8.2 Extraction Approach

Prompt Ollama with the bill text and ask for structured JSON:

```
Extract billing details from the following document.

Return JSON in this format:
{
  "provider": "AGL",
  "account_number": "123456789",
  "billing_period_start": "2025-01-01",
  "billing_period_end": "2025-01-31",
  "total_amount": 187.50,
  "line_items": [
    {"label": "Peak electricity usage", "kwh": 312, "rate_cents": 28.5, "amount": 88.92},
    {"label": "Off-peak usage", "kwh": 145, "rate_cents": 12.1, "amount": 17.55},
    {"label": "Supply charge", "days": 31, "rate_cents": 108.0, "amount": 33.48},
    {"label": "GST", "amount": 14.00},
    {"label": "Concessions/rebates", "amount": -12.00}
  ]
}

If a field is not present in the document, use null.
Only return valid JSON — no explanation.

Document text:
{text}
```

### 8.3 Phase 2 Trigger

This sub-feature activates when `core.tax_documents.tax_category_id` maps to:
- `Work From Home — Electricity/Gas`
- `Work From Home — Internet`
- Any `utility-bill` category

Phase 1 (launch): classify and file only. Phase 2: extract line items.

---

## 9. Python Script Design

**Location**: `prod/scripts/extract_folder_tax_docs.py`

**Dependencies**:
- `pdfplumber` — PDF text extraction
- `requests` — Ollama API calls
- `psycopg2` — DB writes
- `pathlib` — file operations
- `hashlib` — file hash for integrity check
- `shutil` — safe file move

**Algorithm**:

```python
# Pseudocode — full implementation in next session
BINDUMP = Path("/data/tax-collector/bindump")
ROOT = Path("/data/tax-collector")
OLLAMA_URL = "http://192.168.0.93:11434/api/generate"
SUPPORTED_EXTS = {'.pdf', '.png', '.jpg', '.jpeg', '.tiff', '.docx'}

def run():
    batch_id = log_start()
    files = list(BINDUMP.glob("*"))
    files = [f for f in files if f.is_file() and f.suffix.lower() in SUPPORTED_EXTS]

    results = {"extracted": 0, "failed": 0, "skipped": 0}

    for f in files:
        try:
            text = extract_text(f)                    # pdfplumber or vision
            classification = classify(f.name, text)   # Ollama
            dest = build_dest_path(classification, f)  # YYYY-YYYY/category/filename
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest = safe_move(f, dest)                  # handles collision suffix
            land(batch_id, f, dest, text, classification)
            results["extracted"] += 1
        except Exception as e:
            log_error(batch_id, f, e)
            results["failed"] += 1

    log_complete(batch_id, results)
```

---

## 10. n8n Workflow: TC_EXTRACT_FOLDER

**WIP name**: `WIP_TC_EXTRACT_FOLDER`
**Location**: `personal > tax-collector > wip`

**Nodes**:
1. **Schedule trigger** — run daily at 02:00 (or manual trigger)
2. **SSH: check bindump** — `ls /data/tax-collector/bindump/ | wc -l`
3. **IF: files exist** — skip if count = 0
4. **SSH: run script** — `python3 /home/howieds/hub/tax-collector/prod/scripts/extract_folder_tax_docs.py`
5. **DB: check results** — `SELECT rows_extracted, rows_loaded, status FROM ctl.process_log WHERE workflow_nme = 'TC_EXTRACT_FOLDER' ORDER BY started_at DESC LIMIT 1`
6. **IF: failures > 0** — send Telegram alert with failure details
7. **Telegram: success summary** (optional — can be noisy, configure separately)

---

## 11. Acceptance Criteria

- [ ] Files dropped in `bindump/` are classified within 60 seconds of the workflow trigger
- [ ] Each file is moved to the correct `YYYY-YYYY/category/subfolder/` path
- [ ] No file is ever deleted — only moved
- [ ] Filename collisions are resolved with timestamp suffix (no overwrite)
- [ ] FY folder is auto-created if it doesn't exist
- [ ] A `core.tax_documents` row exists for each processed file
- [ ] Files with confidence < 0.6 land in `08-receipts-bills/other/` with `review_status = 'NEEDS_REVIEW'`
- [ ] `ctl.process_log` records every run with row counts and status
- [ ] n8n workflow alerts via Telegram on any failure
- [ ] Phase 2: `core.bill_details` row created for utility/WFH bills with extracted line items

---

## 12. Open Items & Migrations

### Migration required (before Phase 2)

```sql
-- Run as n8nusr via: docker exec postgres psql -U n8nusr -d taxcollectordb
-- File: prod/schema/migrations/001_add_bill_details.sql

CREATE TABLE core.bill_details (
    bill_id             SERIAL PRIMARY KEY,
    doc_id              INTEGER NOT NULL REFERENCES core.tax_documents(doc_id),
    provider_nme        VARCHAR(100) NOT NULL,
    account_number      VARCHAR(100),
    billing_period_start DATE,
    billing_period_end   DATE,
    total_amount        NUMERIC(10,2),
    line_items          JSONB NOT NULL DEFAULT '[]',
    extracted_by        VARCHAR(50),
    extraction_confidence NUMERIC(4,3),
    needs_review        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_bill_details_doc ON core.bill_details(doc_id);
CREATE INDEX idx_bill_details_provider ON core.bill_details(provider_nme, billing_period_start);
GRANT ALL PRIVILEGES ON core.bill_details TO taxcollectorusr;
GRANT ALL PRIVILEGES ON SEQUENCE core.bill_details_bill_id_seq TO taxcollectorusr;
COMMENT ON TABLE core.bill_details IS
    'Itemised bill data extracted from utility/insurance/receipt documents. '
    'line_items JSONB is flexible per provider.';
```

### Open items

| # | Item | Impact |
|---|---|---|
| 1 | Confirm Ollama model to use for PDF classification (llama3.2 vs mistral) | Affects classification quality |
| 2 | Confirm whether bindump should process `.docx` files or PDF/image only | Script scope |
| 3 | Confirm Telegram bot token + chat ID for alerts | n8n workflow |
| 4 | Phase 2 priority — when to activate bill line-item extraction | Backlog |
