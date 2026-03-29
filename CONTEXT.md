# CONTEXT.md — Tax Collector

> Live handoff document. Update before ending any session or switching tools.

**Last updated**: 2026-03-29 (session 13 — Full pipeline working; granular bill detail capture next)
**Current mode**: Enhancement — pipeline end-to-end confirmed; extending Ollama prompt for line-item extraction
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
- [x] `prod/workflows/TC_EXTRACT_GMAIL.json` — LIVE, working end-to-end (24 emails processed)
- [x] `prod/workflows/WIP_LOAD_CORE_TAX_DOCS.json` — built, user imports to n8n
- [x] `prod/scripts/process_document.py` — deployed to server, working
- [x] `maintenance/scripts/sp_merge_tax_documents.sql` — deployed to live DB
- [x] `core.tax_documents` — schema extended with enriched columns + trigger + safe_to_date()

### Architecture — LOCKED

**Gmail pipeline (working):**
```
[n8n: TC_EXTRACT_GMAIL — Schedule or Manual]
  → Gmail search (has:attachment filename:pdf, 3-month test window)
  → for each email: download attachment binary → WriteBinaryFile → process_document.py
      (pdfplumber → Ollama qwen2.5:14b → file to TC_DOCS_ROOT → land to landing.tax_documents)
  → [SEPARATE] WIP_LOAD_CORE_TAX_DOCS (manual trigger for now)
      → Start Batch → CALL core.sp_merge_tax_documents(NULL) → Get Counts → Complete Batch
```

**Extract/Load separation (HARD RULE):**
- `TC_EXTRACT_GMAIL` lands to `landing.*` ONLY
- `WIP_LOAD_CORE_TAX_DOCS` calls `sp_merge_tax_documents` and promotes to `core.*`
- `process_document.py` does NOT call the SP — that's the LOAD_CORE workflow's job

**Filing path structure:**
```
/mnt/disk2/data/tax-collector/ = X:\data\tax-collector\ on Windows = /data/tc-docs/ in container
  bindump/                    ← manual drop zone only
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
1. **[NEXT] Granular bill detail capture** — extend Ollama prompt to extract line_items from utility bills
   - line_items: array of {description, period, quantity, unit, rate, amount}
   - Store in raw_json (already JSONB in landing) → flows to core via SP
   - Create `mart.vw_utility_bills` view exposing line_items for solar battery ROI analysis
   - Deploy: update process_document.py → deploy bat → re-run extract on utility bills
2. **Re-run full test** — truncate landing + core (user runs in DBeaver), re-run TC_EXTRACT_GMAIL + WIP_LOAD_CORE_TAX_DOCS
3. **3-year historical backfill** — change Gmail query `after:` date to 2022/07/01 (currently 3-month test window)
4. **mart.vw_utility_bills** — spec 003 section 11 view for solar/utility analysis
5. **DBeaver review workflow** — spec 003 section 9: queries for CONFIRMED/REJECTED tagging
6. **Watermark revert** — currently 3-month test window; revert to full FY/watermark incremental after backfill
7. **Remove test_classify.py** — already deleted from server; delete from maintenance/scripts/ locally

### Open items (lower priority)
- Bendigo Bank CSV columns — confirm when next statement available
- Share broker — CommSec CSV format TBD
- Super fund provider — TBD
- Review UI (Phase 2) — Telegram bot or simple web page for mobile approval

---

## Key Context for Incoming AI

- **Project**: Two-pillar personal finance platform — (1) scan Gmail/folders for ATO tax docs, (2) ingest bank CSVs for financial health analysis
- **Tax year**: July 1 – June 30. Current = FY2025 (Jul 2024 – Jun 2025)
- **DB**: `taxcollectordb` on `192.168.0.250:5432`, user `taxcollectorusr`, env var `TC_DB_PASSWORD`
- **DB superuser**: `n8nusr` (Docker `POSTGRES_USER`) — not `postgres` or `root`
- **DB access**: AI uses `docker exec postgres psql` over SSH (key `~/.ssh/trade_vantage_agent`). User uses DBeaver on Windows dev machine.
- **HARD RULE**: Never autonomously run DROP / TRUNCATE / bulk DELETE. Provide SQL, user runs in DBeaver.
- **Privacy rule**: Never send document content to cloud LLMs — Ollama on Mac Mini (`192.168.0.93:11434`) only
- **LLM model**: `qwen2.5:14b` Q4_K_M on Mac Mini M4 Pro (`192.168.0.93:11434`). Available models: qwen2.5:14b, qwen2.5-coder:14b, qwen2.5-coder:32b-instruct-q3_k_m, llama3.1:latest. **qwen2.5:32b does NOT exist** — do not use.
- **Alerting**: Email to `toshach@gmail.com` via Gmail OAuth2 cred ID `WcOe7o1be8G2TzJ4`. No Telegram/Signal.
- **Gmail OAuth**: App "In production", tokens long-lived. Always reconnect via `n8n.rodinah.dev` (not local IP).
- **Script deploy path**: `X:\automation-io\tax-collector\scripts\` → `/mnt/disk2/automation-io/tax-collector/scripts/` → n8n sees as `/data/tax-collector/scripts/`. Use `bash maintenance/scripts/deploy-scripts.bat` (Windows) to push.
- **n8n Tax Collector DB credential**: ID `GhZL6n0TTt2R9eJ7`, connects to `taxcollectordb` as `taxcollectorusr`
- **Workflow push**: `bash maintenance/scripts/push-workflow.sh prod/workflows/<file>.json` — requires `"_n8nId"` field. First-time creation: omit `_n8nId`.
- **Workflow orchestration**: Child workflows have Manual Trigger + Execute Workflow Trigger. Parent orchestrator handles scheduling. AI builds children only.
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
