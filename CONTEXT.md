# CONTEXT.md — Tax Collector

> Live handoff document. Update before ending any session or switching tools.

**Last updated**: 2026-03-24 (session 5 — architecture locked)
**Current mode**: Build — ready to start
**Active branch**: main

---

## Current Project State

### What exists
- [x] Project scaffold — CLAUDE.md, specs, skills, slash commands
- [x] `specs/PROJECT_MASTER_SPEC.md` — two-pillar master spec (Tax Docs + Financial Health)
- [x] `specs/features/001-database-schema.md` — COMPLETE
- [x] `specs/features/002-gmail-scanner.md` — NEEDS REWRITE (old architecture — Python-based, superseded by decisions below)
- [x] `specs/features/003-folder-scanner.md` — Draft, still valid for manual bindump drops
- [x] `taxcollectordb` provisioned — 5 schemas, 15 tables, 7 mart views, seed data, smoke tests green
- [x] `prod/schema/DDL/` — 8 DDL files (000–006 + smoke test)
- [x] `prod/stored_procedures/sp_merge_tax_documents.sql` — written + deployed to live DB
- [x] `prod/scripts/extract_gmail_tax_docs.py` — written but SUPERSEDED (see below)
- [x] `prod/scripts/setup_gmail_auth.py` — written but SUPERSEDED (not needed — n8n handles auth)
- [x] `landing.tax_documents` dedup index — applied to live DB
- [x] `~/tax-collector/{scripts,config,logs}` — created on Ubuntu server

### Architecture — LOCKED (session 5 decisions)

**Gmail pipeline (n8n-native, single pass):**
```
[n8n: Schedule 6am daily]
  → [n8n: Gmail search] — uses existing Gmail OAuth credential in n8n
      for each matching email:
      ├── HAS PDF ATTACHMENT?
      │     YES → [n8n: Download attachment binary]
      │           → [n8n: Save PDF to server] ~/tax-collector/YYYY-YYYY/category/filename.pdf
      │           → [Execute Command: process_document.py --file <path> --meta <json>]
      │               (Python: pdfplumber extract text → Ollama classify → DB insert)
      │
      └── NO ATTACHMENT
            → [n8n: Extract email body text]
            → [n8n HTTP Request: Ollama] classify + extract key fields
            → [n8n Postgres: Insert landing.tax_documents] (content_preview only)
  → [n8n Postgres: Update watermark]
  → [Error branch: Gmail send alert to toshach@gmail.com]
```

**Folder pipeline (manual drops only):**
```
[n8n: Watch ~/tax-collector/bindump/ for new files]
  → [Execute Command: process_document.py --file <path>]
      (same Python helper as Gmail pipeline)
  → [Move file to YYYY-YYYY/category/]
```

**Shared Python helper: `process_document.py`**
- Input: file path + optional email metadata JSON
- Steps: extract text (pdfplumber) → call Ollama (qwen2.5:14b) → classify → file document → land to DB → call sp_merge
- Used by both Gmail and folder pipelines

**What bindump is for (revised):**
- ONLY manually-dropped files (paper receipts scanned, manually downloaded statements)
- Gmail attachments go DIRECTLY to `YYYY-YYYY/category/` after classification — NOT via bindump

**Filing path structure (confirmed):**
```
/mnt/disk2/data/tax-collector/      ← = X:\data\tax-collector\ on Windows
  bindump/                          ← manual drop zone only
  YYYY-YYYY/                        ← e.g. 2024-2025 (create if missing)
    income/
      payslips/
      interest/
      dividends/
    deductions/
      insurance/
      work-related/
    super/
    health/
    government/               ← ATO notices, HECS
    investments/
    receipts-and-bills/
      utilities/
      other/
```

### What's next (priority order)
1. **Rewrite spec 002** — Gmail scanner (n8n workflow, single-pass, branch on attachment)
2. **Write `prod/scripts/process_document.py`** — shared PDF processor (pdfplumber + Ollama + filing + DB)
3. **Build n8n workflow `WIP_TC_EXTRACT_GMAIL`** — export JSON to `prod/workflows/`
4. **Update spec 003** — folder scanner now only handles bindump manual drops
5. **Build n8n workflow `WIP_TC_SCAN_BINDUMP`**
6. **Write spec 004** — NAB/Bendigo statement ingestor

### Open items
- Bendigo Bank CSV columns — confirm when next statement available (low urgency)
- Share broker — confirm broker name and CSV format (CommSec assumed)
- Super fund provider — TBD (placeholder in DB)
- Ollama prompt design for document classification — needs iteration/testing

---

## Key Context for Incoming AI

- **Project**: Two-pillar personal finance platform — (1) scan Gmail/folders for ATO tax docs, (2) ingest bank CSVs for financial health analysis
- **Tax year**: July 1 – June 30. Current = FY2025 (Jul 2024 – Jun 2025)
- **DB**: `taxcollectordb` on `192.168.0.250:5432`, user `taxcollectorusr`, env var `TC_DB_PASSWORD`
- **DB superuser**: `n8nusr` (Docker `POSTGRES_USER`) — not `postgres` or `root`
- **DB access**: AI uses `docker exec postgres psql` over SSH (key `~/.ssh/trade_vantage_agent`). User uses DBeaver on Windows dev machine.
- **HARD RULE**: Never autonomously run DROP / TRUNCATE / bulk DELETE. Provide SQL, user runs in DBeaver.
- **Privacy rule**: Never send document content to cloud LLMs — Ollama on Mac Mini (`192.168.0.93:11434`) only
- **LLM model**: `qwen2.5:14b` Q4_K_M on Mac Mini M4 Pro (`192.168.0.93:11434`). n8n calls via HTTP Request POST.
- **Alerting**: Email to `toshach@gmail.com` via Gmail OAuth2 cred ID `WcOe7o1be8G2TzJ4`. No Telegram/Signal.
- **Gmail OAuth**: App "In production", tokens long-lived. Credential managed entirely in n8n. Always reconnect via `n8n.rodinah.dev` (not local IP).
- **Script deploy path**: `X:\automation-io\tax-collector\scripts\` → `/mnt/disk2/automation-io/tax-collector/scripts/` → n8n sees as `/data/tax-collector/scripts/`. Use `maintenance\scripts\deploy-scripts.bat` to push from repo.
- **sp_merge_tax_documents**: Deployed. Groups by (source_type, source_id), promotes largest PDF per email to core.
- **Folder paths (server)**: `/mnt/disk2/data/tax-collector/` is the root (= `X:\data\tax-collector\` on Windows, = `sdd` WD 3TB ext4 drive). Subdirs confirmed: `bindump/` (manual drops only) + pre-created year folders `2026-2027` through `2030-2031`. Script must CREATE missing year folders (e.g. `2024-2025` for current FY). `~/tax-collector/{scripts,config,logs}` on home dir is for scripts/config only — NOT document storage.
- **NAB CSV** (verified): Date (`%d %b %y`), Amount, Account Number, Transaction Type, Transaction Details, Balance, Category, Merchant Name, Processed On
- **Statement ingestion**: user drops CSVs into watched folder — no bank API. Dedup via `dedup_hash`.
- **Financial health priority**: (1) spend categories → (2) budget vs actual → (3) anomalies → (4) savings rate → (5) tax cash flow
- **Skills to load**: `skill_tax_collector_core` + `skill_shared_infrastructure`
- **Superseded files** (do not use): `prod/scripts/extract_gmail_tax_docs.py`, `prod/scripts/setup_gmail_auth.py` — Python-based Gmail OAuth approach, replaced by n8n-native

---

## Session Log

### 2026-03-24 (session 5)
- Architecture decisions locked (see Architecture section above)
- Decision 1: Gmail reading via n8n (existing credential) — no Python OAuth needed
- Decision 2: Download attachments directly to YYYY-YYYY/category/ — user needs copies for tax agent
- Decision 3: Handle body-only emails in Phase 1 (same pass, branch in workflow)
- Key insight: bindump is now ONLY for manual drops; Gmail → direct filing
- Key insight: one shared `process_document.py` Python helper serves both Gmail and folder pipelines
- Superseded: `extract_gmail_tax_docs.py`, `setup_gmail_auth.py` — flagged in repo as superseded
- No user actions required to start next session — AI can begin spec rewrite + build immediately
- CONTEXT.md fully updated — incoming AI can start with spec 002 rewrite

### 2026-03-24 (session 4)
- Gmail OAuth reconnected and working — root cause: Cloudflare intercepting callback + session cookie domain mismatch (always reconnect via n8n.rodinah.dev, not local IP)
- Confirmed Gmail app "In production" — tokens long-lived
- Model: `qwen2.5:14b` Q4_K_M chosen for classification
- Alerting: Gmail email only (Law 2 already wired)
- Skill_shared_infrastructure updated with verified model list

### 2026-03-24 (session 3)
- Resolved all 3 blocking open items (OAuth, folder paths, NAB CSV columns)
- Written specs 002 and 003 (both need revision per session 5 architecture decisions)
- Bendigo Bank CSV TBD

### 2026-03-24 (session 2)
- HARD RULE for destructive DB ops codified
- AI autonomy clarified: AI executes all dev/deploy, user should not run scripts

### 2026-03-23 (session 1)
- Project scaffold, master spec, schema spec (001), DB provisioned, smoke tests green
- postgres superuser = `n8nusr`
