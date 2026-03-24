# Tax Collector — Project Master Spec

**Status**: Draft
**Created**: 2026-03-23
**Owner**: toshach@gmail.com
**Last updated**: 2026-03-23

---

## 1. System Purpose

Tax Collector is a personal finance intelligence platform for an Australian household. It has two integrated pillars that share a single database, orchestration layer, and review interface.

**Pillar 1 — Tax Document Intelligence**: Continuously scans Gmail and local/cloud folders for documents relevant to an Australian financial year tax submission (July 1 – June 30). It classifies each document, identifies whether it represents a deductible expense, and produces a structured summary ready for accountant handoff or ATO lodgement.

**Pillar 2 — Financial Health**: Ingests manually-dropped CSV statements from bank accounts (NAB, Bendigo Bank) and investment/share holdings. It categorises transactions, tracks spending patterns, surfaces anomalies, and generates actionable financial health reports.

---

## 2. Explicit Boundaries

### In Scope

| # | Capability |
|---|---|
| 1 | Scan Gmail for tax-relevant documents (invoices, receipts, statements, ATO notices) |
| 2 | Scan local and cloud-synced folders for tax documents |
| 3 | Ingest manually-dropped CSV statements (NAB, Bendigo Bank, share holdings) |
| 4 | Classify documents by tax category and deductibility via Ollama (local LLM) |
| 5 | Categorise financial transactions by spending category via Ollama + rule engine |
| 6 | Track statement completeness and email a reminder when a month is missing |
| 7 | Generate FY tax summary report (deductibles by category, document inventory) |
| 8 | Generate financial health reports (spend breakdown, savings rate, anomalies) |
| 9 | Present a unified review UI for both pillars |

### Out of Scope (explicitly excluded)

| # | Capability | Reason |
|---|---|---|
| 1 | Direct bank API / Open Banking integration | Avoid OAuth complexity; CSV drop is simpler and sufficient |
| 2 | ATO e-lodgement API submission | Out of scope for v1; manual accountant handoff is sufficient |
| 3 | Superannuation fund integration | TBD — provider and format unknown; add in v2 |
| 4 | Trade-vantage portfolio coupling | Systems are independent; share data can be imported via broker CSV |
| 5 | Sending any document content to public cloud LLMs | Privacy requirement — all classification runs locally on Mac Mini |
| 6 | Storing raw document files in the database or repo | Privacy — only metadata and extracted fields stored |

---

## 3. Architecture

### Infrastructure (locked)

| Layer | Component | Address / Path |
|---|---|---|
| Database | PostgreSQL `taxcollectordb` | `192.168.0.250:5432` user `taxcollectorusr` env `TC_DB_PASSWORD` |
| Orchestration | n8n | `192.168.0.250:5678` (local) / `https://n8n.rodinah.dev` (external) |
| Classification LLM | Ollama on Mac Mini M4 Pro | `http://192.168.0.93:11434` model `qwen2.5-coder:32b-instruct-q3_k_m` |
| Dev machine | Windows 11 | `c:\Users\tosha\repos\tax-collector\` |
| Script deploy path | Ubuntu server via X: drive | `X:\automation-io\scripts\` → `/data/scripts/` in n8n container |
| Watched folder (statements) | Local Windows folder | `c:\Users\tosha\Documents\TaxCollector\statements\` (TBC with user) |
| Watched folder (tax docs) | Local Windows folder | `c:\Users\tosha\Documents\TaxCollector\tax-docs\` (TBC with user) |
| Error alerts | Gmail OAuth2 | ID `WcOe7o1be8G2TzJ4` → `toshach@gmail.com` |

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  SOURCES                                                         │
│  Gmail API  │  Local Folders  │  CSV Drop Folder                │
└──────┬──────┴────────┬────────┴────────┬────────────────────────┘
       │               │                 │
       ▼               ▼                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  EXTRACT (n8n TC_EXTRACT_* workflows → Python scripts)          │
│  extract_gmail_tax_docs.py │ extract_folder_tax_docs.py         │
│  extract_financial_statements.py                                │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  LANDING SCHEMA (raw staging — watermark-tracked)               │
│  landing.tax_documents │ landing.financial_transactions         │
│  landing.share_transactions                                     │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  LOAD CORE (n8n TC_LOAD_CORE_* workflows → sp_merge_*.sql)      │
│  Idempotent UPSERT: landing → core                              │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  CORE SCHEMA (normalised warehouse)                             │
│  core.tax_documents │ core.financial_transactions               │
│  core.share_transactions                                        │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  CLASSIFY (n8n TC_CLASSIFY_* workflows → Python + Ollama)       │
│  classify_tax_documents.py │ classify_transactions.py           │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  MART SCHEMA (analytical views — read-only)                     │
│  vw_tax_documents │ vw_tax_summary │ vw_monthly_spending        │
│  vw_spending_by_category │ vw_savings_rate │ vw_anomalies       │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  REPORT + REVIEW                                                │
│  report_tax_summary.py │ report_financial_health.py             │
│  prod/frontend/ (unified review UI)                             │
└─────────────────────────────────────────────────────────────────┘
```

### Database Schema Map

| Schema | Purpose | Write source |
|---|---|---|
| `landing` | Raw staging — append-only, watermark-tracked | Python extractors |
| `core` | Normalised, deduplicated warehouse | sp_merge_* stored procedures |
| `mart` | Analytical views — read-only | Created as PostgreSQL views |
| `ref` | Reference lookups (categories, accounts, FY periods) | Seed data + admin |
| `ctl` | Audit, control, config, process log | All pipelines |

---

## 4. Domain Model (10 bounded contexts)

Each context maps to one feature spec in `specs/features/`.

### 001 — Database Schema
**Purpose**: Define and provision all schemas, tables, views, indexes, and seed data.
**Input**: None (DDL execution against blank DB).
**Output**: Working `taxcollectordb` with all schemas.
**Depends on**: Nothing — built first.

### 002 — Gmail Scanner
**Purpose**: Scan Gmail inbox for tax-relevant emails and attachments for the current FY.
**Input**: Gmail OAuth2 credentials, tax year boundary (Jul 1 – Jun 30).
**Output**: Rows inserted into `landing.tax_documents`.
**Key rules**: Search by label + keywords (ATO, tax, invoice, receipt, statement, insurance, superannuation). Filter by received date within FY. Extract metadata only — no email body or attachment content stored in DB.

### 003 — Folder Scanner
**Purpose**: Scan watched local/cloud folders for tax-relevant documents.
**Input**: Configured folder paths, file extensions (.pdf, .jpg, .png, .csv, .xlsx).
**Output**: Rows inserted into `landing.tax_documents`.
**Key rules**: Watermark-based incremental scan (file modified date). Skip files already processed (dedup by file hash).

### 004 — Financial Statement Ingestor
**Purpose**: Parse manually-dropped CSV statement files and load to landing.
**Input**: CSV files dropped into watched folder. Provider auto-detected from filename or header.
**Output**: Rows inserted into `landing.financial_transactions` or `landing.share_transactions`.
**Supported providers**:

| Provider | Format notes |
|---|---|
| NAB | Date, Amount, Payee, Description, Balance |
| Bendigo Bank | Date, Debit, Credit, Balance, Transaction Type, Reference, Description |
| Share holdings | Trade Date, Security, Quantity, Price, Value — broker TBD |
| Super fund | TBD — add in v2 |

**Key rules**: Normalise to canonical schema. Deduplicate by (account_id, txn_date, amount, description_hash). Move processed file to `/processed/` subfolder. Log source file + row count to `ctl.process_log`.

### 005 — Document Classifier
**Purpose**: Classify tax documents in `core.tax_documents` — assign category and deductibility.
**Input**: Unclassified rows in `core.tax_documents` (where `tax_category_id IS NULL`).
**Output**: Updated `core.tax_documents` with `tax_category_id`, `is_deductible`, `deductible_amount`, `confidence_score`.
**Model**: Ollama `qwen2.5-coder:32b-instruct-q3_k_m` on Mac Mini. Prompt includes: subject, sender, filename, content_preview. Response must be JSON.
**Privacy**: Only metadata fields sent to Ollama — no raw document content, no attachment binary.

### 006 — Transaction Classifier
**Purpose**: Categorise financial transactions in `core.financial_transactions`.
**Input**: Unclassified rows (where `category_id IS NULL`).
**Output**: Updated `core.financial_transactions` with `category_id`, `subcategory`, `is_deductible`, `confidence_score`.
**Strategy**: Two-pass — (1) rule engine matches known merchant patterns first (fast, deterministic); (2) Ollama classifies remaining rows.
**Model**: Same Ollama endpoint as Document Classifier.

### 007 — Statement Reminder
**Purpose**: Alert the user when a monthly statement is missing for any account.
**Input**: `ctl.statement_watermark` — last loaded statement date per account.
**Output**: Email to `toshach@gmail.com` listing which accounts are missing which months.
**Schedule**: Runs weekly (every Monday 8am). Checks last 3 months. Skips if statement present.

### 008 — Tax Reporter
**Purpose**: Generate FY tax summary for accountant handoff.
**Input**: `mart.vw_tax_summary`, `mart.vw_tax_documents`.
**Output**: Structured JSON + human-readable Markdown report. Optionally exported to PDF.
**Sections**: Total deductible expenses by category, document inventory, work-from-home calculation, income summary.

### 009 — Financial Health Reporter
**Purpose**: Generate actionable financial health reports from transaction data.
**Input**: `mart.vw_monthly_spending`, `mart.vw_spending_by_category`, `mart.vw_savings_rate`, `mart.vw_anomalies`.
**Output**: Monthly report delivered by email + available in review UI.
**Features** (in priority order — see Section 5).

### 010 — Frontend Review UI
**Purpose**: Unified web interface for reviewing tax documents and financial health data.
**Input**: mart schema views.
**Output**: Browser-accessible dashboard.
**Technology**: TBD (React, plain HTML, or Metabase dashboard — decide at spec time).
**Built last** — all data pipelines must be complete before UI begins.

---

## 5. Financial Health Features (priority order)

| Priority | Feature | Description | Min data needed |
|---|---|---|---|
| 1 | Spending category breakdown | All transactions grouped and totalled by category | 1 month |
| 2 | Monthly budget vs. actual | Spend per category vs. user-set (or auto-derived) budget | 1 month |
| 3 | Anomaly alerts | Transactions that are statistical outliers vs. category baseline | 3 months |
| 4 | Savings rate over time | Monthly income minus spend → savings % trend | 3 months |
| 5 | Tax year cash flow summary | Total income, total spend, total deductibles in FY | 1 FY |
| 6 | Debt reduction planning | Balance tracking + payoff projections | User input needed |
| 7 | Net worth / asset tracking | Bank + shares + super − debts | All sources connected |

---

## 6. Australian Tax Year Rules

| Rule | Value |
|---|---|
| Tax year | July 1 – June 30 |
| Current FY | FY2025 (July 1 2024 – June 30 2025) |
| ATO lodgement deadline | October 31 (or May 31 via registered tax agent) |
| Date filter — Gmail scan | `after:2024/07/01 before:2025/06/30` |
| Date filter — SQL | `txn_date BETWEEN '2024-07-01' AND '2025-06-30'` |

### Work-From-Home Deduction (key use case)
The user works from home and may claim:
- Portion of home internet bills
- Portion of electricity/gas bills
- Home and contents insurance (home office portion)
- Income protection insurance (fully deductible)
- Technology equipment (keyboard, mouse, hard drives, monitors)
- Software subscriptions (LLM subscriptions, productivity tools)
- Professional development (training courses, certifications)
- Professional memberships

All of these categories must be captured in `ref.tax_categories` with `is_deductible = true`.

---

## 7. Privacy Rules (non-negotiable)

| Rule | Detail |
|---|---|
| No document content to cloud LLMs | Only metadata fields (subject, sender, filename, file size, content_preview ≤ 500 chars) sent to Ollama |
| No raw files in DB | File metadata only — file stays on disk or in cloud storage |
| No raw files in repo | No tax documents, statements, or financial data committed to git |
| No .env files in repo | Credentials via environment variables only; `TC_DB_PASSWORD` set on server |
| Classification on Mac Mini only | Ollama at `192.168.0.93:11434` — never OpenAI, Anthropic, or other cloud APIs |
| No actual amounts in logs | Log row counts and batch IDs only — never individual transaction amounts |

---

## 8. n8n Workflow Naming Convention

| Prefix | Purpose | Example |
|---|---|---|
| `TC_EXTRACT_*` | Run Python extractor → write to landing | `TC_EXTRACT_GMAIL` |
| `TC_LOAD_CORE_*` | Run sp_merge_* → UPSERT landing → core | `TC_LOAD_CORE_TAX_DOCS` |
| `TC_CLASSIFY_*` | Run classifier → update core | `TC_CLASSIFY_TAX_DOCS` |
| `TC_REPORT_*` | Generate and email reports | `TC_REPORT_FINANCIAL_HEALTH` |
| `TC_REMIND_*` | Scheduled reminders | `TC_REMIND_MISSING_STATEMENTS` |
| `WIP_TC_*` | Work-in-progress (user tests before promoting) | `WIP_TC_EXTRACT_GMAIL` |

**Three Laws** apply to all TC workflows:
1. Double-Wall Timeout — timeout at workflow level AND in executeCommand node
2. Error Alerting — every error path: log ERROR → send alert → Stop And Error
3. Batch ID — all `ctl.process_log` INSERTs must end with `RETURNING batch_id`

---

## 9. Success Criteria

### Pillar 1 — Tax Document Intelligence
- [ ] Gmail scanner correctly identifies and stages tax-relevant emails for FY2025
- [ ] Folder scanner picks up new documents within 1 hour of being dropped
- [ ] Document classifier assigns correct tax category with ≥ 80% accuracy on test set
- [ ] Tax summary report lists all deductible documents grouped by ATO category
- [ ] Work-from-home deductions are captured and calculated correctly
- [ ] Full pipeline (scan → classify → report) runs end-to-end without manual intervention

### Pillar 2 — Financial Health
- [ ] NAB CSV statements import correctly with zero duplicate transactions
- [ ] Bendigo Bank CSV statements import correctly with zero duplicate transactions
- [ ] Share holdings CSV imports correctly
- [ ] Transaction classifier assigns correct spending category with ≥ 85% accuracy
- [ ] Monthly spending breakdown available within 1 hour of dropping a statement
- [ ] Statement reminder fires correctly when a month's data is missing
- [ ] Anomaly detection flags at least 1 known test anomaly in test dataset

### Infrastructure
- [ ] All pipelines are idempotent — re-running produces same result, no duplicates
- [ ] All pipelines log to `ctl.process_log` with batch_id
- [ ] All pipelines send error alerts on failure
- [ ] DB schema can be provisioned from scratch via DDL scripts in ≤ 5 minutes

---

## 10. Open Items (to resolve before relevant feature spec)

| # | Item | Blocks |
|---|---|---|
| 1 | Watched folder paths — confirm exact Windows paths for statement and tax-doc drops | 003, 004 |
| 2 | Gmail OAuth2 credentials setup | 002 |
| 3 | Share holdings broker — confirm which broker and sample CSV format | 004 |
| 4 | Super fund provider and statement format | 004 (v2) |
| 5 | Budget targets — does user want to set these manually or auto-derive from first 3 months? | 009 |
| 6 | Frontend technology choice — React, plain HTML, or Metabase? | 010 |

---

## 11. Related Specs

| File | Purpose |
|---|---|
| `specs/features/001-database-schema.md` | Full schema definition — all tables, DDL, smoke test |
| `specs/features/002-gmail-scanner.md` | Gmail extraction pipeline |
| `specs/features/003-folder-scanner.md` | Folder extraction pipeline |
| `specs/features/004-financial-statement-ingestor.md` | CSV normalisation and ingestion |
| `specs/features/005-document-classifier.md` | Tax document classification |
| `specs/features/006-transaction-classifier.md` | Transaction categorisation |
| `specs/features/007-statement-reminder.md` | Missing statement alerting |
| `specs/features/008-tax-reporter.md` | FY tax summary generation |
| `specs/features/009-financial-health-reporter.md` | Financial health reporting |
| `specs/features/010-frontend-review-ui.md` | Unified review interface |
| `specs/memory/constitution.md` | Non-negotiable architectural principles |
