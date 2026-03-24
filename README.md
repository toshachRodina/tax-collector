# Tax Collector

Automated document intelligence for Australian tax year submissions.

Scans Gmail and local/cloud folders, classifies tax-relevant documents (income statements, invoices, receipts, ATO notices), and produces a structured summary ready for accountant handoff or ATO lodgement.

## Tax Year Coverage
- FY2025: July 1, 2024 – June 30, 2025
- FY2024: July 1, 2023 – June 30, 2024

## Stack
- **Orchestration**: n8n at `192.168.0.250:5678`
- **Storage**: PostgreSQL at `192.168.0.250:5432` (`taxcollectordb`)
- **Classification**: Mac Mini M4 Pro Ollama (`qwen2.5-coder:32b`)
- **Extraction**: Python scripts (Gmail API, folder scanning)

## Getting Started
See `specs/features/` for the feature roadmap. Start with `/new-task` to kick off a task with full context.
