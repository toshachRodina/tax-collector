# CONTEXT.md — Tax Collector

> Live handoff document. Update before ending any session or switching tools.

**Last updated**: 2026-04-18 (session 17 — bank pipeline refined; orchestration confirmed fully live)
**Current mode**: All pipelines live and running daily at 18:00. Bank CSV pipeline active. Schema refinements pending DB deploy.
**Active branch**: master

---

## Current Project State

### What exists
- [x] Project scaffold — CLAUDE.md, specs, skills, slash commands
- [x] `specs/PROJECT_MASTER_SPEC.md` — two-pillar master spec (Tax Docs + Financial Health)
- [x] `specs/features/001-database-schema.md` — COMPLETE
- [x] `specs/features/002-gmail-scanner.md` — REWRITTEN for n8n-native architecture ✓
- [x] `specs/features/003-merge-to-core.md` — WRITTEN (session 13)
- [x] `taxcollectordb` provisioned — 5 schemas, 15 tables, 7 mart views, seed data, smoke tests green
- [x] `prod/schema/DDL/` — 8 DDL files (000–006 + smoke test)
- [x] `prod/workflows/WIP_EXTRACT_GMAIL.json` — LIVE working workflow (replaces TC_EXTRACT_GMAIL.json which never worked reliably). Loops over individual emails, not bulk. Has watermark + 3-day buffer + 2022-07-01 fallback.
- [x] `prod/workflows/TC_EXTRACT_GMAIL.json` — SUPERSEDED. Do not use. WIP_EXTRACT_GMAIL.json is the working one.
- [x] `prod/workflows/WIP_LOAD_CORE_TAX_DOCS.json` — built, user imports to n8n
- [x] `prod/workflows/EXTRACT_FOLDER.json` — LIVE in n8n (ID: `kvxTsvvnjeeR4Y1S`). Smoke test passed 12 files.
- [x] `prod/workflows/LOAD_CORE_TAX_DOCS.json` — updated in n8n (ID: `n3HnEC6y2NE651YAMXW6t`) with few-shot + classify loop
- [x] `prod/scripts/process_document.py` — deployed to server, working
- [x] `prod/scripts/extract_folder_tax_docs.py` — LIVE at `/data/tax-collector/scripts/`. SHA-256 dedup, pdfplumber, Ollama classification with few-shot, safe file move to YYYY-YYYY archive.
- [x] `maintenance/scripts/sp_merge_tax_documents.sql` — deployed to live DB
- [x] `core.tax_documents` — schema extended with enriched columns + trigger + safe_to_date()
- [x] `prod/schema/DDL/007_tax_checklist.sql` — ref.tax_checklist_items + ref.tax_checklist_responses + 13 new ref.tax_categories
- [x] `prod/schema/DDL/008_tax_checklist_seed.sql` — 32 DOCUMENT items + 21 RESPONSE items + FY2025 UNKNOWN defaults
- [x] `prod/schema/DDL/009_tax_checklist_view.sql` — mart.vw_checklist_completeness (SATISFIED/MISSING/NOT_APPLICABLE/UNKNOWN/N/A)
- [x] `prod/workflows/SEED_CHECKLIST_QUESTIONNAIRE.json` — annual HMAC-signed yes/no email per applicability group
- [x] `prod/workflows/HANDLE_CHECKLIST_RESPONSE.json` — webhook validates token, updates all items in group, returns HTML confirmation
- [x] `specs/features/006-tax-checklist-completeness.md` — full spec
- [x] Metabase: Tax Checklist FY2025 dashboard (dashboard 10) — 4 cards live. Layouts fixed on Home/Review Queue/FY Summary.

### Architecture — LOCKED

**Gmail pipeline (working):**
```
[n8n: WIP_EXTRACT_GMAIL — Manual trigger]  ← THIS IS THE WORKING ONE
  → Gmail search (has:attachment filename:pdf, watermark-based after:date)
  → Loop Over Emails (one at a time)
  → for each email: download attachment binary → WriteBinaryFile → process_document.py
      (pdfplumber → Ollama qwen2.5:14b → file to TC_DOCS_ROOT → land to landing.tax_documents)
  → [SEPARATE] WIP_LOAD_CORE_TAX_DOCS (manual trigger)
      → Start Batch → CALL core.sp_merge_tax_documents(NULL) → Get Counts → Complete Batch
```

**Extract/Load separation (HARD RULE):**
- `TC_EXTRACT_GMAIL` lands to `landing.*` ONLY
- `WIP_LOAD_CORE_TAX_DOCS` calls `sp_merge_tax_documents` and promotes to `core.*`
- `process_document.py` does NOT call the SP — that's the LOAD_CORE workflow's job

**Filing path structure:**
```
/mnt/disk2/data/tax-collector/ = X:\data\tax-collector\ on Windows = /data/tc-docs/ in container
  staging/                    ← drop zone for folder scanner (was called bindump in older specs)
  YYYY-YYYY/
    income/payslips/ | interest/ | dividends/
    deductions/work-related/ | insurance/
    super/ | health/ | government/ | investments/
    receipts-and-bills/utilities/ | other/
```

**File naming**: `{Supplier Name} - {original_filename}.pdf` (supplier prefix added by build_dest_path)

### What's confirmed working (session 13)
- 24 emails processed end-to-end: extract → land → merge → core
- `core.tax_documents` has 24 rows with correct data (supplier names, billing dates, amounts, confidence)
- Sample: GloBird Energy (confidence 1.0, AUTO_CONFIRMED, billing_start/end populated, $219.49)
- review_status: confidence >= 0.75 → AUTO_CONFIRMED, else NEEDS_REVIEW
- ON CONFLICT preserves user-reviewed records (CONFIRMED/REJECTED)
- Filed files at correct network-visible path: X:\data\tax-collector\2025-2026\...

### What's next (priority order)

1. **Add Metabase dashboard cards**:
   - "Bank Interest Income FY2025" — sum from `mart.vw_bank_interest_income` on FY Summary dashboard
   - "Missing Receipt Indicators" — table from `mart.vw_missing_receipt_indicators` on FY Summary dashboard

4. **Smoke test bank pipeline** — drop a NAB CSV in staging, trigger PIPELINE_BANK_TXNS manually, verify `has_matching_document` populated and `vw_missing_receipt_indicators` shows gaps

### Open items (lower priority)
- Bendigo Bank CSV columns — confirm when next statement available
- Share broker — CommSec CSV format TBD
- Super fund provider — TBD
- Review UI (Phase 2) — Telegram bot or simple web page for mobile approval
- Line-item extraction from utility bills — V2 (solar battery ROI analysis)

---

## Key Context for Incoming AI

- **Project**: Two-pillar personal finance platform — (1) scan Gmail/folders for ATO tax docs, (2) ingest bank CSVs for financial health analysis
- **Tax year**: July 1 – June 30. Current = FY2025 (Jul 2024 – Jun 2025)
- **DB**: `taxcollectordb` on `192.168.0.250:5432`, user `taxcollectorusr`, env var `TC_DB_PASSWORD`
- **DB superuser**: `n8nusr` (Docker `POSTGRES_USER`) — not `postgres` or `root`
- **DB access**: AI uses `docker exec postgres psql` over SSH (key `~/.ssh/trade_vantage_agent`). User uses DBeaver on Windows dev machine.
- **HARD RULE**: Never autonomously run DROP / TRUNCATE / bulk DELETE. Provide SQL, user runs in DBeaver.
- **Privacy rule**: Never send document content to cloud LLMs — Ollama on Mac Mini (`192.168.0.96:11434`) only
- **LLM model**: `qwen2.5:14b` Q4_K_M on Mac Mini M4 Pro (`192.168.0.96:11434`). Available models: qwen2.5:14b, qwen2.5-coder:14b, qwen2.5-coder:32b-instruct-q3_k_m, llama3.1:latest. **qwen2.5:32b does NOT exist** — do not use.
- **Alerting**: Email to `toshach@gmail.com` via Gmail OAuth2 cred ID `WcOe7o1be8G2TzJ4`. No Telegram/Signal.
- **Gmail OAuth**: App "In production", tokens long-lived. Always reconnect via `n8n.rodinah.dev` (not local IP).
- **Script deploy path**: `X:\automation-io\tax-collector\scripts\` → `/mnt/disk2/automation-io/tax-collector/scripts/` → n8n sees as `/data/tax-collector/scripts/`. Use `bash maintenance/scripts/deploy-scripts.bat` (Windows) to push.
- **n8n Tax Collector DB credential**: ID `GhZL6n0TTt2R9eJ7`, connects to `taxcollectordb` as `taxcollectorusr`
- **Workflow push**: `bash maintenance/scripts/push-workflow.sh prod/workflows/<file>.json` — requires `"_n8nId"` field. First-time creation: omit `_n8nId`.
- **Workflow orchestration**: Child workflows have Manual Trigger + Execute Workflow Trigger. Parent orchestrator handles scheduling. AI builds children only.
- **WORKING WORKFLOW**: `WIP_EXTRACT_GMAIL.json` is the live Gmail extractor. `TC_EXTRACT_GMAIL.json` is superseded — do not reference it.
- **Watermark**: `WIP_EXTRACT_GMAIL` → Get Watermark queries `core.tax_documents` MAX(received_at) - 3 days. Empty core → falls back to `2022-07-01`. Build Gmail Query uses `parseInt(watermark_ms)` (bigint comes as string from Postgres).
- **sp_merge_tax_documents**: Called with NULL (not a batch_id) — processes ALL unprocessed landing rows. Has safe_to_date() for invalid LLM dates. Classification model hardcoded as 'qwen2.5:14b'.
- **TC_DOCS_ROOT**: `/data/tc-docs` in container = `/mnt/disk2/data/tax-collector/` on host = `X:\data\tax-collector\` on Windows
- **review_status values**: AUTO_CONFIRMED (confidence >= 0.75), NEEDS_REVIEW (< 0.75), AUTO_REJECTED (not used yet), CONFIRMED, REJECTED (user-set via DBeaver)
- **process_document.py**: Lands everything regardless of is_tax_relevant — the SP's review_status is the quality gate
- **Execute Command expressions**: `=plain string {{ expr }}` format. Never pass binary as shell args (E2BIG). Container shell is `/bin/sh` (busybox — no bash).
- **n8n JsTaskRunner**: `$json` is Proxy — use `$input.all()` with `runOnceForAllItems`. `require('fs')` blocked.
- **WriteBinaryFile**: Requires `N8N_RESTRICT_FILE_ACCESS_TO=/data/tax-collector` in docker-compose.
- **Destructive ops rule (extended)**: Applies to n8n workflow API deletions too — always confirm with user.
- **Skills to load**: `skill_tax_collector_core` + `skill_shared_infrastructure`
- **Superseded files**: `prod/scripts/extract_gmail_tax_docs.py`, `prod/scripts/setup_gmail_auth.py` — do not use

---

## Session Log

### 2026-04-18 (session 17) — Bank pipeline refined; orchestration confirmed live; Redash vs Metabase decided

**What was done:**
- **Confirmed orchestration fully live**: `RUN_DAILY_TC` (18:00 daily, ID `KrdjQ1fohP4WySo7`) calls `PIPELINE_EXRACTS` → `NOTIFY_REVIEW` → `PIPELINE_BANK_TXNS`. EXTRACT_FOLDER already wired — no manual action needed (CONTEXT.md was stale).
- **Confirmed bank pipeline live**: `EXTRACT_BANK_CSV` (ID `Dat4ilzBc3bw1UIC`) + `LOAD_CORE_BANK` (ID `NJJXRGO0WmRaz1Qe`) running. DDL `010_bank_transactions.sql` deployed and tables populated.
- **Simplified bank transaction categorisation logic**: Addressed user's valid question — bank transactions are NOT a deductions list. The pipeline's two legitimate purposes are: (1) bank interest income declaration (ATO requirement) and (2) gap detection (flagged categories with no matching document in core.tax_documents).
- **Added `has_matching_document` column** to `core.bank_transactions` schema (via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` in DDL — idempotent). Pending DB deploy.
- **Added two new mart views**: `mart.vw_bank_interest_income` (interest rows for ATO declaration) and `mart.vw_missing_receipt_indicators` (flagged categories with no matching document). Pending DB deploy.
- **Updated `LOAD_CORE_BANK.json`**: Merge SQL now sets `has_matching_document` via EXISTS cross-check against `core.tax_documents`. Interest rows auto-CONFIRMED. Get Counts updated to report `total_interest_rows` and `total_missing_receipts`. Pending n8n push.
- **Written `sp_merge_bank_transactions.sql`**: Full stored procedure alternative to inline SQL — promotes landing → core with all classification logic. Also re-evaluates `has_matching_document` for existing NEEDS_REVIEW rows on each run (so gaps close as documents arrive). Pending DB deploy.
- **Updated `extract_bank_csv.py`**: Renamed `DEDUCTIBLE_NAB_CATEGORIES` → `FLAGGED_NAB_CATEGORIES` with corrected purpose comments. Backwards-compatible alias retained. Pending script deploy.
- **Fixed spec 003**: All `bindump` references replaced with `staging`. Title updated.
- **Redash vs Metabase research completed**: Decision = stay with Metabase. Redash is community-led only (Databricks dropped it), requires 3+ Docker services vs 1, and has less native drill-through. Metabase wins for solo home server use.

**Key decisions:**
- Bank transactions are GAP INDICATORS and ATO income, not a deductions list. The receipt IS the deductible item.
- `has_matching_document` cross-checks supplier name + 60-day date window — fuzzy but sufficient for gap detection.
- Interest rows auto-CONFIRMED (no human review needed — ATO income is deterministic).
- Metabase stays — no migration to Redash warranted.

**Pending user actions (deploy sequence):**
1. Run `ALTER TABLE + mart views` SQL in DBeaver (from DDL 010 sections 4-5)
2. AI deploys `sp_merge_bank_transactions.sql` via SSH once user confirms step 1
3. AI pushes updated `LOAD_CORE_BANK.json` to n8n
4. AI deploys updated `extract_bank_csv.py` via `bash maintenance/scripts/deploy-scripts.bat`
5. Smoke test: drop NAB CSV, trigger pipeline, verify `has_matching_document` + new mart views

### 2026-04-07 (session 16) — Tax checklist, folder scanner, few-shot, Metabase all live

**What was done:**
- **Tax Checklist (Spec 006)**: DDL 007-009 deployed to DB — `ref.tax_checklist_items` (32 doc + 21 response items), `ref.tax_checklist_responses`, `mart.vw_checklist_completeness`. 13 new categories added to `ref.tax_categories`.
- **Checklist workflows**: `SEED_CHECKLIST_QUESTIONNAIRE` (annual HMAC yes/no email) + `HANDLE_CHECKLIST_RESPONSE` (webhook, updates applicability_group atomically).
- **n8n naming convention applied**: REVIEW_ACTION → HANDLE_REVIEW_ACTION, CHECKLIST_RESPONSE → HANDLE_CHECKLIST_RESPONSE, SEND_CHECKLIST_QUESTIONNAIRE → SEED_CHECKLIST_QUESTIONNAIRE, GMAIL → RUN_GMAIL_PIPELINE. All 8 workflows tagged `tax-collector`.
- **n8n folder structure**: 0-archive, 1-orchestrators, 2-landing, 3-core, 4-mart, 5-webhooks, 6-notify, 7-setup, wip — user tidied in UI.
- **Metabase**: Tax Checklist dashboard (ID 10) with 4 cards created. Layout fixes on Home (pie shrunk, bar full-width), Review Queue (pending table height 4→10), FY Summary (scalars widened to fill row). Nav bars on all 5 dashboards updated with checklist link.
- **DBeaver review confirmed complete**: 241 CONFIRMED + 120 REJECTED = 361 total, zero pending.
- **Folder scanner (Spec 003 Phase 1)**: `extract_folder_tax_docs.py` written and deployed. SHA-256 cross-source dedup, pdfplumber, Ollama classification with few-shot examples from DB, safe file move, landing insert.
- **EXTRACT_FOLDER workflow** (ID: `kvxTsvvnjeeR4Y1S`): count staging → skip if empty → run script → check process_log → email alert on failure → call LOAD_CORE_TAX_DOCS.
- **Few-shot loop**: `LOAD_CORE_TAX_DOCS` (ID: `n3HnEC6y2NE651YAMXW6t`) updated with 5 new nodes — fetches last 10 CONFIRMED/REJECTED examples, classifies unclassified Gmail landing records via Ollama, updates raw_json before merge proc runs.
- **3 bugs fixed in folder extractor** (caught during smoke test): check_duplicate queried wrong table; content_preview too long; NUL bytes in PDF text.
- **Smoke test (execution 17629)**: 12/19 staging files landed successfully (4 duplicates, 3 CSVs skipped). Full chain ran through LOAD_CORE_TAX_DOCS.

**Key decisions:**
- Drop zone is `/data/tc-docs/staging/` (was called `bindump` in older specs — update spec 003).
- CSVs (bank statements) skipped by folder scanner — separate pipeline needed.
- `TC_DOCS_ROOT` env var used in script so paths work inside n8n container.
- EXTRACT_FOLDER is active:false — user must add to RUN_DAILY_TC manually (parent orchestrator rule).

**Next session starts with:** Commit session work, add EXTRACT_FOLDER to RUN_DAILY_TC in n8n UI, then bank CSV ingestion spec.

---

### 2026-04-07 (session 15) — EXTRACT_FOLDER workflow created; folder extractor smoke test green

**What was done:**
- Retrieved n8n API key from `user_api_keys` table (`agentic access` key)
- PUT updated `LOAD_CORE_TAX_DOCS` (ID: `n3HnEC6y2NE651YAMXW6t`) — new few-shot classification loop added
- POST created `EXTRACT_FOLDER` workflow (ID: `kvxTsvvnjeeR4Y1S`) — `_n8nId` written to JSON file
- Confirmed `extract_folder_tax_docs.py` deployed at `/data/tax-collector/scripts/`
- Confirmed `/data/tc-docs/staging/` accessible from n8n container (19 files present at time of check)
- Fixed 3 bugs in `extract_folder_tax_docs.py`:
  1. `check_duplicate` queried `core.tax_documents.raw_json` (column doesn't exist) → changed to `landing.tax_documents`
  2. `content_preview = text_content[:2000]` → `[:500]` (column is `varchar(500)`)
  3. NUL bytes in PDF text → `text_content.replace('\x00', '')` before slice
- Smoke test execution 17629: SUCCESS — all 8 nodes ran including `Load Core Tax Docs` chain

**Key decisions:**
- n8n login password is `Fletcher$00` (not `Fletcher00`)
- n8n workflow trigger requires `destinationNode: ""` + `runData: null` + `pinData: {}` + full `workflowData` object
- Scripts volume mount: `/mnt/disk2/automation-io/tax-collector/scripts/` on host → `/data/tax-collector/scripts/` in container

**Next session starts with:** Run LOAD_CORE_TAX_DOCS to merge folder-extracted landing rows to core, then review in DBeaver.

---

### 2026-03-30 (session 14) — 3-year backfill complete; review + training loop next

**What was done:**
- Confirmed `WIP_EXTRACT_GMAIL.json` is the working workflow — `TC_EXTRACT_GMAIL.json` is permanently superseded
- Clarified context auto-compression (user doesn't need to manage it; `/handoff` only needed before genuinely closing chat)
- Confirmed: 24 reviewed records (CONFIRMED/REJECTED) are NOT sufficient for few-shot training yet — wait for post-backfill review
- Truncated `core.tax_documents` and `landing.tax_documents` in DBeaver (user ran)
- Fixed watermark: Get Watermark query updated to use `2022-07-01` fallback + 3-day buffer; Build Gmail Query fixed with `parseInt(watermark_ms)` (bigint comes as string from Postgres — was causing Invalid Date)
- 3-year backfill ran — 360 emails processed successfully over ~4 hours
- 1 email failed (last one): Barron's crypto article — apostrophe in filename broke shell single-quote arg. Not a tax doc, no rerun needed. Fix pending in `safeName` regex.

**Key decisions:**
- Few-shot feedback loop deferred until post-backfill review produces diverse labelled set
- Water bills: NOT claimable under ATO home office rules — reject them
- Ambiguous records (e.g. Officeworks paper for someone else): leave as NEEDS_REVIEW with reviewer_notes, hand to accountant
- Confidence score = model certainty about classification, NOT deductibility — high confidence wrong answers are expected for out-of-scope purchases
- Keep `core.tax_documents` intact between runs — ON CONFLICT preserves CONFIRMED/REJECTED; no need to truncate for weekly incremental runs

**Next session starts with:** Run WIP_LOAD_CORE_TAX_DOCS to merge 360 landing rows to core, then review backfill results in DBeaver.

---

### 2026-03-29 (session 13) — Full pipeline working; line-item extraction next

**What was done (sessions 12b–13):**
- Fixed Ollama model: reverted from qwen2.5:32b (doesn't exist) back to qwen2.5:14b
- Updated prompt: explicit TRUE/FALSE rules for Australian tax relevance
- Fixed NUL byte error: `raw_json.replace('\x00', '')` + `_clean()` helper for string fields
- Removed `is_tax_relevant` gate from `process_document.py` — land everything, review_status is the gate
- Removed `call_sp_merge()` from `main()` — LOAD_CORE workflow handles merges
- Added supplier name file prefix: `GloBird Energy - Invoice10058516.pdf`
- Fixed file paths: TC_DOCS_ROOT=/data/tc-docs → correct network-visible path
- Extended `core.tax_documents` schema: supplier_name, account_ref, supply_address, document_date, billing_start, billing_end, total_amount, gst_amount, filed_path, reviewed_at + trigger
- Updated `sp_merge_tax_documents.sql`: new columns, safe_to_date(), review_status logic, NULL batch_id support
- Built `WIP_LOAD_CORE_TAX_DOCS.json`: full workflow with error path, SP called with NULL
- Wrote `specs/features/003-merge-to-core.md`
- Confirmed: 24 emails → 24 core rows, correct supplier names, dates, amounts, review_status

**Key decisions:**
- SP always called with NULL (not batch_id) — landing rows have EXTRACT batch_ids, not LOAD_CORE batch_ids
- Everything lands (no LLM gate at extract time) — human reviews in core via DBeaver
- review_status CHECK includes: AUTO_CONFIRMED, AUTO_REJECTED, NEEDS_REVIEW, CONFIRMED, REJECTED

**Next session starts with:** Extending Ollama prompt to capture line_items from utility bills (description, period, qty, unit, rate, amount) for solar battery ROI analysis. Then mart.vw_utility_bills view.

---

### 2026-03-28 (sessions 11–12) — TC_EXTRACT_GMAIL working end-to-end

- Write and Process node fixed: WriteBinaryFile pipeline avoids E2BIG, `=str {{ expr }}` format confirmed
- N8N_RESTRICT_FILE_ACCESS_TO=/data/tax-collector added to docker-compose
- 24 emails processed successfully
- Watermark changed from landing to core table (landing is cleared each run)

---

### 2026-03-27 (sessions 9–10) — Attachment download rewritten

- Gmail downloadAttachments broken in v2.6.4 — replaced with HTTP Request chain
- Tag Messages fixed: runOnceForAllItems + $input.all()
- Code node runOnceForEachItem fails for large items (IPC null for >300KB)
- Merge node diamond pattern broken in n8n 2.6.4

---

### 2026-03-26 (sessions 7–8) — Infrastructure, credentials, workflow architecture

- Tax Collector DB credential created (ID: GhZL6n0TTt2R9eJ7)
- TC_DB_PASSWORD + TC_DOCS_ROOT added to docker-compose
- pdfplumber added to n8n-build Dockerfile
- Extract/Load isolation decision locked
- Watermark redesigned (self-healing COALESCE)

---

### 2026-03-25 (session 6) — Core scripts and workflow written

- process_document.py written (pdfplumber → Ollama → file → land)
- TC_EXTRACT_GMAIL.json built (23 nodes)

---

### 2026-03-24 (sessions 1–5) — Project scaffold and DB

- taxcollectordb provisioned, 5 schemas, smoke tests green
- Architecture decisions locked (n8n-native Gmail, shared process_document.py)
- NAB CSV format verified
