# Feature Spec 003 — Merge to Core

**Status**: Draft
**Last updated**: 2026-03-29
**Depends on**: 001-database-schema, 002-gmail-scanner
**Blocks**: 004-review-ui, 005-analytics-views

---

## 1. Overview

The Merge to Core workflow promotes documents from `landing.tax_documents` (raw capture) into `core.tax_documents` (the normalised warehouse layer). This is where the system makes definitive decisions about tax relevance, deductibility, and review priority.

Landing is deliberately permissive — it captures everything with any plausible financial connection. Core is where quality gates are applied, review flags are set, and the record becomes the source of truth for reporting and accountant handoff.

---

## 2. Goals

- Promote all unprocessed landing rows to core with enriched classification
- Apply a tighter LLM assessment (higher confidence threshold, stricter criteria) than the landing pass
- Assign a `review_status` to every core record so the user knows what needs attention
- Store normalised financial fields (amount, dates, supplier) as first-class columns for querying
- Provide the foundation for a feedback/training loop — user-reviewed records become labelled examples

---

## 3. Architecture

```
[n8n: Schedule — or triggered by EXTRACT_GMAIL on completion]
    ↓
[n8n: Postgres — Start Batch]         INSERT ctl.process_log RETURNING batch_id
    ↓
[n8n: Postgres — Get Unprocessed]     SELECT from landing.tax_documents WHERE is_processed = FALSE
    ↓
[n8n: Split In Batches]               loop 1 at a time
    │
    ├── [n8n: HTTP Request — Ollama]  Re-classify with tighter prompt (if confidence was < 0.75)
    │                                  OR use existing classification if confidence >= 0.75
    │       ↓
    ├── [n8n: Code — Build Core Row]  Assign review_status, normalise fields
    │       ↓
    ├── [n8n: Postgres — Upsert Core] CALL core.sp_merge_tax_documents(batch_id)
    │       ↓
    └── [n8n: Postgres — Mark Landed] UPDATE landing SET is_processed=TRUE WHERE landing_id=N
    │
[n8n: Postgres — Complete Batch]
```

---

## 4. Review Status Values

Every core record gets one of these five values, set automatically at merge time:

| Status | When assigned |
|---|---|
| `auto_accepted` | `is_tax_relevant=true` AND `confidence >= 0.75` |
| `pending_review` | `is_tax_relevant=true` AND `confidence < 0.75` — needs user confirmation |
| `auto_rejected` | `is_tax_relevant=false` — stored for audit, excluded from reports |
| `user_accepted` | User has manually confirmed it is relevant |
| `user_rejected` | User has manually marked it as irrelevant |

Records with `auto_rejected` are **kept in core** — they are not deleted. This preserves the full audit trail and lets the user override a bad automatic decision.

---

## 5. Core Table Schema

The existing `core.sp_merge_tax_documents` stored procedure targets `core.tax_documents`. The following schema additions are required before this workflow can run:

```sql
-- New columns to add to core.tax_documents
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS review_status   VARCHAR(20)  NOT NULL DEFAULT 'pending_review'
    CHECK (review_status IN ('auto_accepted','auto_rejected','pending_review','user_accepted','user_rejected'));
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS confidence       NUMERIC(4,3);
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS supplier_name    VARCHAR(500);
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS account_ref      VARCHAR(200);
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS billing_start    DATE;
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS billing_end      DATE;
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS document_date    DATE;
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS total_amount     NUMERIC(12,2);
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS gst_amount       NUMERIC(12,2);
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS supply_address   VARCHAR(500);
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS reviewed_at      TIMESTAMPTZ;
ALTER TABLE core.tax_documents ADD COLUMN IF NOT EXISTS review_note      TEXT;
```

---

## 6. Ollama Re-Classification (Tighter Prompt)

The merge pass runs a second Ollama call only when landing confidence is below 0.75. The tighter prompt:

- Uses `qwen2.5:32b`
- Adds few-shot examples derived from `user_accepted` / `user_rejected` records already in core (up to 5 each, most recent first) — this is the training feedback loop
- Has stricter is_tax_relevant criteria — borderline cases must have clear financial relevance to Australian tax
- Returns the same JSON structure as the landing prompt plus `line_items` (array of {description, quantity, unit, rate, amount})

For records already at confidence >= 0.75, the existing classification from `landing.raw_json` is used as-is — no second Ollama call.

---

## 7. Business Rules

- **Rule 1**: `is_processed` on `landing.tax_documents` is set TRUE only after a successful core upsert — guarantees no records are lost if the workflow fails mid-run
- **Rule 2**: `ON CONFLICT DO UPDATE` on core — reruns update existing records rather than creating duplicates
- **Rule 3**: `auto_rejected` records are stored in core but excluded from all mart views by default — a `include_rejected=true` flag on views makes them optionally visible
- **Rule 4**: User sets `review_status` directly via DBeaver query (Phase 1) or review UI (Phase 2) — AI never updates `user_accepted` / `user_rejected`
- **Rule 5**: `reviewed_at` is stamped when status transitions to `user_accepted` or `user_rejected` — use a Postgres trigger
- **Rule 6**: The watermark for this workflow is separate from EXTRACT_GMAIL — it tracks `landing_id` of the last processed row, not email date

---

## 8. Filing & Folder Strategy

Folders are created dynamically by `process_document.py` using `mkdir(parents=True, exist_ok=True)`. The FY year is determined from the document date (Ollama extracts it), not the scan date. This means:

- A 3-year historical scan will automatically create `2021-2022/`, `2022-2023/`, `2023-2024/`, `2024-2025/` subfolders under each category as documents are processed — no manual folder setup required
- Running the scanner across 3 years: change the Gmail query `after:` date in `Build Gmail Query` — the watermark start date drives the scan window
- Duplicate files on re-run are overwritten (same Gmail source_id = same destination path = safe overwrite)

Structure created automatically:
```
/data/tax-collector/docs/
  2021-2022/
    deductions/work-related/
    income/payslips/
    ...
  2022-2023/
    ...
  2024-2025/
    deductions/work-related/
    income/interest/
    ...
```

---

## 9. Review Workflow (Phase 1 — DBeaver)

Before a review UI is built, the user reviews via DBeaver:

```sql
-- What needs review
SELECT landing_id, source_id, subject, supplier_name, total_amount,
       document_date, category_nme, confidence, review_status
FROM core.tax_documents
WHERE review_status = 'pending_review'
ORDER BY confidence, document_date DESC;

-- Accept a record
UPDATE core.tax_documents
SET review_status = 'user_accepted', reviewed_at = NOW()
WHERE landing_id = <id>;

-- Reject a record
UPDATE core.tax_documents
SET review_status = 'user_rejected', reviewed_at = NOW(), review_note = 'personal expense'
WHERE landing_id = <id>;
```

---

## 10. Training Feedback Loop

When the Ollama re-classify call is made (confidence < 0.75), the prompt is prefixed with up to 5 `user_accepted` and 5 `user_rejected` examples from core:

```
Examples of TAX RELEVANT documents (user confirmed):
- "AGL electricity bill March 2024 — Work From Home — Electricity/Gas — $187.50"
- "Anthropic API subscription — Software & Subscriptions — $124.00"

Examples of NOT tax relevant documents (user confirmed):
- "Uber Eats order confirmation — food delivery — $34.50"
- "Event ticket — concert — $95.00"

Now classify the following document:
...
```

This improves accuracy over time without model retraining.

---

## 11. Solar / Utility Analysis View

Because the user wants historical utility bill data for solar battery ROI analysis, a mart view will expose line-item detail:

```sql
-- mart.vw_utility_bills (future)
SELECT document_date, billing_start, billing_end, supplier_name,
       total_amount, gst_amount,
       raw_json->'classification'->'line_items' AS line_items,
       supply_address, account_ref
FROM core.tax_documents
WHERE category_nme IN ('Work From Home — Electricity/Gas', 'Work From Home — Internet')
ORDER BY billing_start;
```

The `line_items` JSONB field captures the granular billing breakdown (peak, off-peak, solar feed-in, daily charge etc.) from Ollama extraction — exactly what's needed for battery ROI modelling.

---

## 12. Open Items

- [ ] **Schema changes**: Run ALTER TABLE statements above in DBeaver before workflow is built. Confirm `core.tax_documents` current columns first.
- [ ] **sp_merge update**: `core.sp_merge_tax_documents` needs to be updated to write the new columns (review_status, confidence, supplier_name, etc.)
- [ ] **Trigger for reviewed_at**: Create a Postgres trigger on `core.tax_documents` that sets `reviewed_at = NOW()` when review_status transitions to user_accepted/user_rejected
- [ ] **Historical scan window**: Decide the `after:` date for the 3-year backfill run (suggest `2022/07/01`)
- [ ] **Ollama timeout**: 32b model may need OLLAMA_TIMEOUT increased beyond 120s for complex documents — monitor process_log for timeouts
- [ ] **Review UI**: Phase 2 feature — simple web page or Telegram bot for approving/rejecting pending_review records from mobile

---

## 13. Acceptance Criteria

- Given landing rows with `is_processed=FALSE`
  When merge workflow runs
  Then each row has a corresponding `core.tax_documents` record with `review_status` set appropriately

- Given a landing row with `confidence >= 0.75`
  When merged
  Then no second Ollama call is made — existing classification is used

- Given a landing row with `confidence < 0.75`
  When merged
  Then Ollama is called again with tighter prompt and few-shot examples

- Given a document classified `auto_rejected`
  When mart views are queried
  Then it does not appear in default output (only with `include_rejected=true`)

- Given the user sets `review_status = 'user_rejected'`
  When the next merge run fires with the same source_id
  Then `ON CONFLICT DO UPDATE` preserves `user_rejected` — it is not overwritten by the auto classifier

- Given a 3-year historical scan
  When documents from FY2022, FY2023, FY2024 are processed
  Then folders `2021-2022/`, `2022-2023/`, `2023-2024/` are created automatically under each category
