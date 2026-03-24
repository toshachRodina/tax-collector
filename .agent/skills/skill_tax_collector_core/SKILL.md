---
name: skill_tax_collector_core
description: Core technical facts for the Tax Collector project. Database name, connection strings, document categories, Australian tax year rules, Gmail API setup, and project-specific operational rules. Load for any task touching this project's DB, pipelines, or document logic. Always load skill_shared_infrastructure alongside this.
---

# Tax Collector — Core Technical Specifications

Single source of truth for the Tax Collector project. Always load `skill_shared_infrastructure/SKILL.md` alongside this for server/infra facts.

---

## 1. Project Purpose

Scan Gmail inboxes and local/cloud folders for documents relevant to Australian tax year submissions. Classify, store metadata, and produce a structured summary for accountant handoff or ATO lodgement.

---

## 2. Australian Tax Year

| Field | Value |
|---|---|
| Tax year boundary | **July 1 – June 30** |
| FY2025 | July 1, 2024 – June 30, 2025 |
| FY2024 | July 1, 2023 – June 30, 2024 |
| FY2023 | July 1, 2022 – June 30, 2023 |
| ATO lodgement deadline | Typically October 31 (or May 31 via tax agent) |

All date filtering, watermarks, and reports must respect the July 1 – June 30 boundary.

---

## 3. Database

- **Host**: `192.168.0.250:5432`
- **DB**: `taxcollectordb`
- **User**: `taxcollectorusr`
- **Status**: Not yet created (awaiting first spec implementation)

### Python Connection Pattern
```python
import psycopg2, os

conn = psycopg2.connect(
    host="192.168.0.250",
    port="5432",
    database="taxcollectordb",
    user="taxcollectorusr",
    password=os.environ.get("TC_DB_PASSWORD")
)
```

> Note: Use env var `TC_DB_PASSWORD` (not `DB_PASSWORD`) to avoid conflicts with trade-vantage.

### Schema Map

| Schema | Status | Purpose |
|---|---|---|
| `landing` | TBD | Raw staging — email metadata, attachment refs |
| `core` | TBD | Normalized document records |
| `mart` | TBD | Summary views by tax year, document type |
| `ref` | TBD | Document categories, ATO codes, deduction types |
| `ctl` | TBD | Audit log, process tracking |

---

## 4. Document Categories (Draft)

Tax-relevant document types to be classified:

| Category | Examples |
|---|---|
| Income | Payment summaries, group certificates, bank interest statements, dividend statements |
| Deductions | Work-related receipts, home office invoices, professional development |
| Property | Rental income/expense statements, depreciation schedules |
| Health | Private health insurance statements (PHI) |
| Government | ATO notices, MyGov correspondence, HECS/HELP statements |
| Investments | Brokerage statements, CGT events, crypto tax reports |
| Super | Superannuation statements, contribution notices |
| Other | Any document with ABN references, TFN references, or financial figures |

---

## 5. Gmail API (Not Yet Configured)

- OAuth2 credentials will be stored in `ctl.ctrl_vars` (encrypted via pgcrypto) — NOT in the repo
- Gmail API scopes needed: `gmail.readonly`, `gmail.labels`
- Search strategy: Label-based + keyword-based (ATO, tax, invoice, receipt, etc.) filtered by date range (tax year)
- Attachment handling: Download to temp, extract text/metadata, store metadata in DB, discard actual file

---

## 6. Folder Scanning (Not Yet Configured)

Sources to scan (TBD with user):
- Local Windows folders (e.g., `C:\Users\tosha\Documents\Tax\`)
- OneDrive / Google Drive (via sync folder or API)
- X: drive mapped folders on server

---

## 7. n8n Workflow Naming (Tax Collector)

| Prefix | Purpose |
|---|---|
| `TC_EXTRACT_*` | Gmail/folder scanning |
| `TC_LOAD_CORE_*` | Merge landing → core |
| `TC_CLASSIFY_*` | Document classification via Ollama |
| `TC_REPORT_*` | Generate summary reports |

WIP prefix: `WIP_TC_*`
n8n folder: `personal > tax-collector > wip`

---

## 8. Privacy Rules

- **Never** send actual document content (PDFs, email bodies with financial data) to public cloud LLMs
- Classification must run on **Mac Mini Ollama** (`http://192.168.0.93:11434`)
- Only metadata (document type, date, amount if extracted, sender) stored in PostgreSQL
- Actual files stay on the local machine or synced cloud storage — never in this repo
- DB contains: file paths/references, extracted metadata, classification labels — NOT file content

---

## 9. Repository Structure

```
tax-collector/
├── CLAUDE.md
├── CONTEXT.md
├── README.md
├── .agent/
│   ├── skills/
│   │   ├── skill_shared_infrastructure/SKILL.md  ← always-on
│   │   ├── skill_tax_collector_core/SKILL.md      ← always-on
│   │   └── skill_python_data_engineer/SKILL.md
├── .claude/
│   └── commands/                                  ← slash commands
├── specs/
│   ├── memory/constitution.md
│   ├── template/                                  ← spec templates
│   └── features/                                  ← feature specs go here
├── prod/                                          ← SACRED
│   ├── scripts/
│   ├── workflows/
│   ├── stored_procedures/
│   └── schema/
├── dev/                                           ← .md only
├── docs/
└── archive/
```
