# Feature Spec 002 — Gmail Scanner

**Status**: Active — supersedes draft from 2026-03-24
**Last updated**: 2026-03-25 (session 6 — rewritten for n8n-native architecture)
**Depends on**: 001-database-schema
**Blocks**: None (parallel to 003, 004)

---

## 1. Overview

The Gmail Scanner scans a Gmail inbox daily for tax-relevant documents in the current Australian financial year (July 1 – June 30). It is implemented entirely as an n8n workflow — no Python-based Gmail authentication or API calls. Gmail OAuth is managed natively within n8n using an existing credential.

The pipeline runs in a single pass per email and branches on whether the email has a PDF attachment:

- **Has PDF attachment** → download binary, save to staging, call `process_document.py` (pdfplumber → Ollama → file to disk → land to DB → sp_merge)
- **No attachment** → extract email body text in n8n, classify via Ollama HTTP Request, insert row directly to `landing.tax_documents`

Both paths land metadata to `landing.tax_documents`. Both call `core.sp_merge_tax_documents` afterwards. The watermark is managed by n8n Postgres nodes (not Python).

---

## 2. Architecture

```
[n8n: Schedule — 6am AEST daily]
    ↓
[n8n: Postgres — Start Batch]       INSERT ctl.process_log RETURNING batch_id
    ↓
[n8n: Postgres — Get Watermark]     SELECT ctl.ctrl_vars for LAST_INTERNAL_DATE_MS
    ↓
[n8n: Code — Build Gmail Query]     FY dates + watermark → Gmail search string
    ↓
[n8n: Gmail — Get All Messages]     getAll, returnAll: true, format: full
    ↓
[n8n: Code — Tag Messages]          parse parts, tag hasAttachment, build stagingPath + metaJson
    ↓
[n8n: IF — Has Attachment?]
    │
    ├── YES ──────────────────────────────────────────────────────────────────
    │   [n8n: Gmail — Download Attachment]  get message with binary data
    │       ↓
    │   [n8n: Write Binary File]            save to /data/tax-collector/staging/{id}_{filename}
    │       ↓
    │   [n8n: Execute Command]              timeout 570 python3 /data/tax-collector/scripts/process_document.py
    │                                         --file {stagingPath} --meta '{metaJson}' --source-type GMAIL
    │
    └── NO ───────────────────────────────────────────────────────────────────
        [n8n: Code — Extract Body Text]     decode base64 body, strip HTML
            ↓
        [n8n: HTTP Request — Ollama]        POST 192.168.0.93:11434/api/generate
            ↓
        [n8n: Code — Parse Ollama Response] build landing row dict
            ↓
        [n8n: Postgres — Insert Landing Row] INSERT landing.tax_documents ON CONFLICT DO NOTHING
            ↓
        [n8n: Postgres — Merge Body to Core] CALL core.sp_merge_tax_documents(batch_id)

[Merge — combine both branches]
    ↓
[n8n: Code — Aggregate Results]     max internalDate, counts
    ↓
[n8n: Postgres — Update Watermark]  UPSERT ctl.ctrl_vars
    ↓
[n8n: Postgres — Complete Batch]    UPDATE process_log status='SUCCESS'

Error path (Law 2):
[Postgres — Fail Batch] → [Gmail — Send Error Alert to toshach@gmail.com] → [Stop And Error]
```

---

## 3. Gmail Search Query

The query is built in a Code node, using the watermark date (if available) or the FY start date:

```
has:attachment filename:pdf after:YYYY/MM/DD before:YYYY/MM/DD (
  "invoice" OR "statement" OR "receipt" OR "tax" OR "ATO" OR "deduction" OR
  "interest" OR "dividend" OR "insurance" OR "payslip" OR "group certificate" OR
  "HECS" OR "superannuation" OR "depreciation"
)
```

**Date logic:**
- `after:` = watermark date if one exists, else FY start (July 1 of current FY start year)
- `before:` = min(today, FY end June 30) + 1 day (Gmail `before:` is exclusive)
- Current FY determined from JS: `fyEndYear = today.getMonth() >= 6 ? today.getFullYear() + 1 : today.getFullYear()`

**First run (no watermark):** scans full current FY — potentially hundreds of emails, but only once.

**Incremental run:** only emails newer than the last successfully processed message.

---

## 4. Watermark Strategy

Watermark is stored as an encrypted value in `ctl.ctrl_vars`:

| Column | Value |
|---|---|
| `package_nme` | `'TC_EXTRACT_GMAIL'` |
| `var_nme` | `'LAST_INTERNAL_DATE_MS'` |
| `var_val` | Gmail `internalDate` of the most recently processed message (epoch milliseconds), encrypted via `pgp_sym_encrypt` |

**Read (Get Watermark node):**
```sql
SELECT pgp_sym_decrypt(var_val::bytea, current_setting('app.encryption_key'))::text AS watermark_ms
FROM ctl.ctrl_vars
WHERE package_nme = 'TC_EXTRACT_GMAIL' AND var_nme = 'LAST_INTERNAL_DATE_MS';
```

**Write (Update Watermark node):** runs after all messages processed. Updates to the max `internalDate` seen across this run.

**Watermark is not updated if the run fails** — the FAILED status in `ctl.process_log` means the next run will re-scan the same window.

---

## 5. Attachment Branch — PDF Processing

### 5.1 Download and Stage

The Gmail "Download Attachment" node fetches the full message with binary attachment data. The "Write Binary File" node saves it to:

```
/data/tax-collector/staging/{messageId}_{sanitisedFilename}
```

The staging directory (`/data/tax-collector/staging/`) must exist and be writable inside the n8n container. Create it manually on first deploy:
```bash
ssh howieds@192.168.0.250
mkdir -p /mnt/disk2/automation-io/tax-collector/staging
```

### 5.2 process_document.py

The Execute Command node calls:
```bash
timeout 570 python3 /data/tax-collector/scripts/process_document.py \
  --file /data/tax-collector/staging/{stagingPath} \
  --meta '{metaJson}' \
  --source-type GMAIL
```

The `--meta` JSON contains: `source_id` (Gmail message ID), `subject`, `sender_email`, `received_at` (ISO), `file_name`, `file_ext`, `file_size_bytes`.

What `process_document.py` does:
1. Extracts text from PDF with pdfplumber
2. Sends text to Ollama (`qwen2.5:14b` on `192.168.0.93:11434`) for classification
3. Determines filing path: `{TC_DOCS_ROOT}/YYYY-YYYY/{category_subdir}/{filename}`
4. Moves file from staging to filing path (creates directory if needed)
5. Inserts to `landing.tax_documents` with classification result in `raw_json`
6. Calls `core.sp_merge_tax_documents(batch_id)`
7. Updates `ctl.process_log` to SUCCESS or FAILED
8. Exits 0 on success, 1 on failure

### 5.3 Document Filing Paths

`TC_DOCS_ROOT` env var (default: `/data/tax-collector/docs`). Category → subdirectory mapping:

| Category | Subdirectory |
|---|---|
| Payment Summary / Group Certificate | `income/payslips/` |
| Bank Interest Statement | `income/interest/` |
| Dividend Statement | `income/dividends/` |
| Share Sale / CGT Event | `investments/` |
| Work From Home — Internet/Electricity/Technology/Software/etc. | `deductions/work-related/` |
| Work From Home — Insurance, Income Protection Insurance | `deductions/insurance/` |
| ATO Notice / Assessment, HECS/HELP Statement | `government/` |
| Superannuation Statement, Super Contribution Notice | `super/` |
| Private Health Insurance Statement | `health/` |
| Rental Income Statement, Property Depreciation Schedule | `investments/` |
| Invoice / Receipt — Other (fallback) | `receipts-and-bills/other/` |

Final path example: `/data/tax-collector/docs/2024-2025/income/payslips/MyPayslip_Oct2024.pdf`

> **Mount note**: `TC_DOCS_ROOT` must be a path accessible within the n8n Docker container. Currently `/data/tax-collector/` maps to `/mnt/disk2/automation-io/tax-collector/` on the host. If document storage should live at `/mnt/disk2/data/tax-collector/` (the `X:\data\tax-collector\` share), a second volume mount must be added to the n8n service in `homelab-hub/docker-compose.yml`.

---

## 6. Body-Only Branch — Email Text Classification

For emails without PDF attachments, the pipeline classifies the email body text directly in n8n:

1. **Extract Body Text** (Code node): decode base64 body data, strip HTML tags, fall back to Gmail `snippet`
2. **Ollama Classify** (HTTP Request): POST to `http://192.168.0.93:11434/api/generate`
   - Model: `qwen2.5:14b`, `stream: false`, `format: json`, timeout: 120,000ms
   - Prompt includes subject + body text (truncated to 4000 chars)
   - Response: `{category, fy_year, is_deductible, deductible_amount, confidence, summary}`
3. **Parse Ollama Response** (Code node): extract classification, build landing row
4. **Insert Landing Row** (Postgres): `INSERT INTO landing.tax_documents ... ON CONFLICT DO NOTHING`
   - `file_name`, `file_ext`, `file_size_bytes` are NULL for body-only rows
   - `content_preview`: first 500 chars of body text
   - `raw_json`: `{classification, body_text_length}`
5. **Merge to Core** (Postgres): `CALL core.sp_merge_tax_documents(batch_id)`

---

## 7. Watermark Update and Batch Completion

After both branches complete and the Merge node combines results:

1. **Aggregate Results** (Code): find max `internalDate` across all processed messages, count success/fail
2. **Update Watermark** (Postgres): UPSERT `ctl.ctrl_vars` with max `internalDate` (encrypted)
3. **Complete Batch** (Postgres): `UPDATE ctl.process_log SET status='SUCCESS', rows_extracted=N, rows_loaded=N, completed_at=NOW()`

---

## 8. Three Laws Compliance

| Law | Implementation |
|---|---|
| Law 1 — Double-Wall Timeout | `settings.executionTimeout: 600` (workflow). Execute Command: `timeout 570 python3 ...` |
| Law 2 — Error Alerting | Error path: Postgres(FailBatch) → Gmail OAuth2 SendMessage(toshach@gmail.com) → StopAndError. Cred ID: `WcOe7o1be8G2TzJ4` |
| Law 3 — Batch ID | Start Batch INSERT ends with `RETURNING batch_id`. `batchId` passed through all subsequent nodes via `$items("Build Gmail Query")[0].json.batchId` |

Also: `settings.errorWorkflow: "oFeU0bOzAsRxU910"` as fallback for infrastructure-level failures.

---

## 9. n8n Workflow

- **Development name**: `WIP_TC_EXTRACT_GMAIL`
- **n8n folder**: `personal > tax-collector > wip`
- **Promoted name**: `TC_EXTRACT_GMAIL` (move to `personal > tax-collector` after user testing)
- **Export file**: `prod/workflows/WIP_TC_EXTRACT_GMAIL.json`

### 9.1 Node List

| # | Node | Type | Notes |
|---|---|---|---|
| 1 | Schedule — Daily 6am AEST | scheduleTrigger | cron `0 20 * * *` UTC |
| 2 | Start Batch | postgres | INSERT process_log RETURNING batch_id |
| 3 | Get Watermark | postgres | SELECT ctl.ctrl_vars |
| 4 | Build Gmail Query | code | JS: compute FY + watermark → query string |
| 5 | Gmail — Get All Messages | gmail | getAll, returnAll, format: full |
| 6 | Tag Messages | code | parse parts, tag hasAttachment, build stagingPath + metaJson |
| 7 | Has Attachment? | if | `{{ $json._tc.hasAttachment }}` |
| 8 | Gmail — Download Attachment | gmail | get, downloadAttachments: true |
| 9 | Save to Staging | writeBinaryFile | write to `/data/tax-collector/staging/` |
| 10 | Process Document | executeCommand | `timeout 570 python3 ...process_document.py` |
| 11 | Check Exit Code | code | parse exitCode, tag success/fail |
| 12 | Gmail — Get Full Message | gmail | get, format: full (no binary) |
| 13 | Extract Body Text | code | base64 decode, strip HTML |
| 14 | Ollama Classify Body | httpRequest | POST to 192.168.0.93:11434 |
| 15 | Parse Ollama + Build Row | code | build landing row dict |
| 16 | Insert Body Landing Row | postgres | INSERT ON CONFLICT DO NOTHING |
| 17 | Merge Body to Core | postgres | CALL sp_merge_tax_documents |
| 18 | Merge Branches | merge | append mode |
| 19 | Aggregate Results | code | max internalDate, counts |
| 20 | Update Watermark | postgres | UPSERT ctl.ctrl_vars |
| 21 | Complete Batch | postgres | UPDATE process_log SUCCESS |
| 22 | Fail Batch | postgres | UPDATE process_log FAILED (error path) |
| 23 | Send Error Alert | gmail | sendMessage to toshach@gmail.com |
| 24 | Stop And Error | stopAndError | terminates workflow |

### 9.2 Credential Bindings

| Credential | n8n Name | Used By |
|---|---|---|
| Gmail OAuth2 | `Gmail OAuth2` (ID: `WcOe7o1be8G2TzJ4`) | Nodes 5, 8, 12, 23 |
| PostgreSQL | `Tax Collector DB` | Nodes 2, 3, 16, 17, 20, 21, 22 |

The `TC_DB_PASSWORD` environment variable must be set in n8n's environment (Docker compose `env_file` or environment section). The Postgres credential in n8n uses the host `192.168.0.250`, database `taxcollectordb`, user `taxcollectorusr`, password from env.

---

## 10. Landing Table Schema

For reference — `landing.tax_documents` (created in spec 001):

```sql
CREATE TABLE landing.tax_documents (
    landing_id      SERIAL PRIMARY KEY,
    batch_id        INTEGER NOT NULL REFERENCES ctl.process_log(batch_id),
    source_type     VARCHAR(20) NOT NULL CHECK (source_type IN ('GMAIL','FOLDER','MANUAL')),
    source_id       VARCHAR(500),          -- Gmail message ID
    subject         VARCHAR(1000),
    sender_email    VARCHAR(500),
    received_at     TIMESTAMPTZ,
    file_name       VARCHAR(500),          -- NULL for body-only rows
    file_ext        VARCHAR(20),           -- NULL for body-only rows
    file_size_bytes INTEGER,               -- NULL for body-only rows
    content_preview VARCHAR(500),
    raw_json        JSONB,                 -- includes filed_path and classification
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_processed    BOOLEAN NOT NULL DEFAULT FALSE
);
-- Dedup index:
CREATE UNIQUE INDEX uidx_landing_tax_docs_dedup
    ON landing.tax_documents(source_type, source_id, COALESCE(file_name, ''));
```

Both branches use `ON CONFLICT (source_type, source_id, COALESCE(file_name, '')) DO NOTHING` to handle reruns safely.

---

## 11. Environment Prerequisites

Before the workflow can run:

1. **pdfplumber in n8n container**: Add to `homelab-hub`'s `n8n-build/Dockerfile`:
   ```dockerfile
   RUN pip install pdfplumber
   ```
   Then rebuild: `docker compose build n8n && docker compose up -d n8n n8n-worker`

2. **Staging directory**: Create once on Ubuntu server:
   ```bash
   mkdir -p /mnt/disk2/automation-io/tax-collector/staging
   ```

3. **process_document.py deployed**: Run `maintenance\scripts\deploy-scripts.bat` from Windows dev machine. Script lands at `/data/tax-collector/scripts/process_document.py` inside n8n container.

4. **TC_DOCS_ROOT configured**: Set in n8n environment or pass as env var in Execute Command node. Default `/data/tax-collector/docs` maps to the automation-io volume. If documents should be stored at `X:\data\tax-collector\`, a separate Docker volume mount is required (homelab-hub change).

5. **TC_DB_PASSWORD in n8n environment**: Must be set so process_document.py can connect to the DB when called via Execute Command.

6. **Postgres credential in n8n**: Create a credential named `Tax Collector DB` pointing to `192.168.0.250:5432 / taxcollectordb / taxcollectorusr`.

---

## 12. Acceptance Criteria

### 12.1 First Run (No Watermark)

- Given no watermark in `ctl.ctrl_vars`
- When the workflow runs
- Then:
  - Full FY scan query is used (`after:` = July 1 of current FY)
  - One `ctl.process_log` row with `workflow_nme='TC_PROCESS_DOCUMENT'` per PDF processed, `status='SUCCESS'`
  - `landing.tax_documents` has rows with `source_type='GMAIL'`
  - `core.tax_documents` has corresponding rows (`review_status='PENDING'`)
  - `ctl.ctrl_vars` has `('TC_EXTRACT_GMAIL', 'LAST_INTERNAL_DATE_MS')` with a valid value
  - PDFs filed to `{TC_DOCS_ROOT}/YYYY-YYYY/{category}/`

### 12.2 Incremental Run (Watermark Exists)

- Given watermark from prior run
- When workflow runs with no new mail
- Then:
  - Gmail query uses watermark date as `after:`
  - No new rows in landing or core
  - `ctl.process_log` has a new row: `rows_extracted=0`, `status='SUCCESS'`

### 12.3 Body-Only Email

- Given an email matching the keyword query but no PDF attachment
- When workflow processes it
- Then:
  - Row inserted to `landing.tax_documents` with `file_name=NULL`, `content_preview` populated
  - `raw_json` contains Ollama classification

### 12.4 Deduplication

- Given an email already processed in a prior run
- When workflow re-encounters same `source_id`
- Then `ON CONFLICT DO NOTHING` fires — no duplicate rows

### 12.5 process_document.py Failure

- Given process_document.py exits 1 (PDF unreadable, Ollama unavailable, etc.)
- When Execute Command detects non-zero exit code
- Then error path fires: `ctl.process_log` FAILED, alert email sent to `toshach@gmail.com`

### 12.6 Multi-Attachment Email

- For MVP: only the first PDF attachment is processed (largest-PDF logic applied in `sp_merge`)
- One row in `landing.tax_documents` per processed attachment
- `sp_merge` promotes the largest PDF to `core.tax_documents`

---

## 13. Open Items

- [ ] **TC_DOCS_ROOT mount**: Confirm whether documents should live on the `automation-io` volume (accessible now) or the `data` volume (`X:\data\tax-collector\`). If the latter, add Docker volume mount to homelab-hub.
- [ ] **pdfplumber Dockerfile**: Build and redeploy n8n after adding `RUN pip install pdfplumber`. Verify with smoke test: `docker exec n8n python3 -c "import pdfplumber; print('ok')"`.
- [ ] **Postgres credential ID**: After creating `Tax Collector DB` credential in n8n, update `prod/workflows/WIP_TC_EXTRACT_GMAIL.json` — replace `TC_DB_CRED_REPLACE_ME` with actual credential ID.
- [ ] **Multi-attachment emails**: MVP processes the first PDF only. If emails with multiple PDFs need all attachments, the Tag Messages and Download Attachment nodes need to loop per-attachment. Defer to v2.
- [ ] **Ollama prompt tuning**: Classification accuracy should be evaluated against a sample of real emails after first run. Prompt iteration is expected.
- [ ] **Staging cleanup**: Processed files are moved by process_document.py, but failed runs leave orphaned files in `/data/tax-collector/staging/`. Add periodic cleanup cron or a cleanup step at workflow start.
