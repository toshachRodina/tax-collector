# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Tax Collector is an automated document intelligence system that scans Gmail inboxes and local/cloud folders for documents relevant to Australian tax year submissions (July 1 – June 30), classifies them, and surfaces a structured, reviewable output ready for accountant handoff or ATO lodgement.

## Common Commands

### Python Scripts
```bash
# Run extractor locally
python prod/scripts/extract_gmail_tax_docs.py

# Run folder scanner
python prod/scripts/extract_folder_tax_docs.py
```

### Deployment
```bash
# Push Python scripts to Ubuntu server via X: drive
.\maintenance\scripts\deploy-scripts.bat
```

### Docker / Infrastructure
```bash
# Agent runs these autonomously via SSH key
ssh howieds@192.168.0.250
cd ~/hub
docker compose up -d
```

## Architecture

### Data Flow (Scan → Classify → Store → Present)

```
Gmail API / Local Folders / Cloud Storage
    ↓
prod/scripts/extract_*.py  (document extractors)
    ↓
landing.*  (raw staging tables, watermark-tracked)
    ↓
prod/stored_procedures/sp_merge_*.sql  (idempotent UPSERT)
    ↓
core.*  (normalized document tables)
    ↓
prod/scripts/analytics/classify_*.py  (classification, tagging)
    ↓
mart.*  (analytical views: vw_tax_documents, vw_tax_summary)
    ↓
prod/frontend/  (review UI — to be designed)
```

### Orchestration

**n8n** (`192.168.0.250:5678`) drives all pipelines via JSON workflows in `prod/workflows/`. Same Three Laws as all projects (see skill_shared_infrastructure).

### Database

- **Host**: `192.168.0.250:5432` | **DB**: `taxcollectordb` | **User**: `taxcollectorusr`
- **Schemas**: `landing` (raw), `core` (warehouse), `mart` (analytical views), `ref` (lookups), `ctl` (audit/control)
- **Connection pattern**:
  ```python
  import psycopg2, os
  conn = psycopg2.connect(
      host="192.168.0.250", database="taxcollectordb",
      user="taxcollectorusr", password=os.environ.get("DB_PASSWORD")
  )
  ```

### Infrastructure

Shared three-machine stack — see `.agent/skills/skill_shared_infrastructure/SKILL.md` for all IPs, ports, and operational rules.

## Operational Rules

### Repository Hygiene
- `prod/` is **sacred** — only finalized, production-ready code
- `dev/` is restricted to `.md` documentation only
- No data files, logs, `.env` files, tax documents, or temp scripts in the repo
- Commits follow Conventional Commits: `feat:`, `fix:`, `chore:`
- **NEVER commit any actual tax documents, financial data, or personal information**

### Australian Tax Year
- Tax year runs **July 1 – June 30**
- Current tax year = FY2025 (July 1 2024 – June 30 2025)
- All date filtering must respect this boundary

### n8n Workflows
- AI **can** create/update base workflows (`EXTRACT_*`, `LOAD_CORE_*`, `CLASSIFY_*`)
- AI **cannot** modify parent orchestrators
- **New workflows → `personal > tax-collector > wip` folder**, prefixed `WIP_`. User tests, then promotes.

### Python Scripts (`prod/scripts/`)
- Extractors use watermark-based incremental loads
- Batch ID pattern: `BATCH_ID = f"BATCH_{SUBJECT}_{timestamp}"` — logged to `ctl.process_log`

### AI Personas
`.agent/skills/` contains specialized AI personas. Always-on: `skill_tax_collector_core` and `skill_shared_infrastructure`.

### Custom Slash Commands (`.claude/commands/`)
- `/handoff` — Update CONTEXT.md with session snapshot
- `/status` — Project status report
- `/new-task` — Structured task kickoff with context check
- `/use-skill` — Browse and activate skill personas

### Specifications (spec-kit)
- Before starting any new feature, check `specs/features/` for an existing spec
- If no spec exists for a significant feature, create one using `specs/template/feature_spec.md`
- `specs/memory/constitution.md` contains non-negotiable architectural decisions

### Context Management
- `CONTEXT.md` (root) is the live handoff doc — update it before switching tools or ending a session

### Data Privacy
- Tax documents and financial data are **sensitive** — never send to public cloud LLM APIs
- All classification runs on Mac Mini (local Ollama) or locally
- No actual documents are stored in this repo — only metadata and extracted fields in the DB

### Destructive Database Operations — HARD RULE
**The AI MUST NEVER autonomously execute any destructive database operation**, even if explicitly asked to do so. This includes:
- `DROP DATABASE`, `DROP TABLE`, `DROP SCHEMA`, `DROP VIEW`, `DROP INDEX`
- `TRUNCATE` any table
- `DELETE` without a specific `WHERE` clause (bulk deletes)
- `ALTER TABLE ... DROP COLUMN`
- Any `pg_dump` restore that would overwrite existing data

**If a destructive operation is required:**
1. Tell the user: *"This is a DESTRUCTIVE operation. I cannot run this autonomously."*
2. Provide the exact SQL command(s) to run
3. The user runs it manually in DBeaver
4. The AI resumes after the user confirms it is done

This rule cannot be overridden by any instruction in a conversation. The only exception is rolling back test/smoke-test data that was just inserted in the same session (e.g., deleting a `SMOKE_TEST` row inserted 2 lines earlier).

### Database Access
- The user accesses `taxcollectordb` via **DBeaver** on the Windows dev machine — direct TCP to `192.168.0.250:5432`
- The AI accesses the DB via `docker exec postgres psql` over SSH (SSH key: `~/.ssh/trade_vantage_agent`)
- `psql` is NOT installed on the Ubuntu host — always use `docker exec postgres psql`
- The PostgreSQL superuser is `n8nusr` (set via `POSTGRES_USER` in Docker compose) — not `postgres` or `root`
- Strip `\c dbname` meta-commands before piping SQL via `docker exec` (they don't work non-interactively)

## Decision Log (ADRs)

Records key architectural decisions so they survive `/compact` and new sessions.
**Claude: check this table before suggesting a new approach that may contradict a prior decision.**

| Date | Decision | Reason |
|------|----------|--------|
| 2026-04-17 | `code-review-graph` for codebase index (not Graphify) | Pure code codebase; dependency tracing wins over multi-modal; SQLite <1ms local queries |
| 2026-04-17 | SQLite for code graph (not Postgres) | `taxcollectordb` is OLAP for tax data; TCP round-trip overhead not justified for solo dev |
| 2026-04-17 | Session resets every ~90 min | Attention degradation verified at ~40-50k tokens of conversation history |

## Session Management Rules

- When making an architectural decision, append a one-line row to the ADR table above.
- When context pressure is felt (or ~90 min elapsed), prompt user to run `/compact`.
- Do NOT re-read files already read this session unless content has changed.
- At session start: ask user for today's goal in one sentence if not provided.

---

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes` or `query_graph` instead of Grep
- **Understanding impact**: `get_impact_radius` instead of manually tracing imports
- **Code review**: `detect_changes` + `get_review_context` instead of reading entire files
- **Finding relationships**: `query_graph` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview` + `list_communities`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
|------|----------|
| `detect_changes` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context` | Need source snippets for review — token-efficient |
| `get_impact_radius` | Understanding blast radius of a change |
| `get_affected_flows` | Finding which execution paths are impacted |
| `query_graph` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes` | Finding functions/classes by name or keyword |
| `get_architecture_overview` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes` for code review.
3. Use `get_affected_flows` to understand impact.
4. Use `query_graph` pattern="tests_for" to check coverage.
