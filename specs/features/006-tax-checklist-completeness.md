# Feature Specification: Tax Checklist Completeness

## Status
[x] Draft
[ ] Review
[ ] Approved
[ ] Implemented
[ ] Deprecated

## Overview

Seed the tax agent's annual checklist into the database, send a once-per-FY email questionnaire to establish which items are applicable, then surface a % complete dashboard in Metabase showing which required documents have been collected vs. still outstanding.

## Context & Motivation

### Business Value
The tax agent provides a checklist (docs/tax_agent/Client Checklist - Individual 2025.doc) that lists every document and response required for lodgement. Without systematic tracking, documents can go missing until the accountant meeting. This feature closes the loop: what's required → what's collected → what's still outstanding.

### User Impact
- At any point before lodgement: open Metabase, see FY2025 is 74% complete, and know exactly which documents are missing.
- No manual list-keeping. The daily Gmail pipeline auto-satisfies checklist items as documents land.

---

## Item Types

The checklist has two fundamentally different item types:

### Type A — DOCUMENT
Requires a physical document to be filed in `core.tax_documents`.
- Counted in % complete.
- A DOCUMENT item is "satisfied" when ≥1 row in `core.tax_documents` matches its `category_tag` for the FY, with `review_status IN ('CONFIRMED', 'AUTO_CONFIRMED')`.

### Type B — RESPONSE
A yes/no or free-text answer captured for form pre-fill. No document required.
- **NOT counted in % complete.**
- Stored in `ref.tax_checklist_responses.response_value` for future form auto-fill (Phase 3).
- Examples: home office hours worked, odometer readings, HECS-HELP Y/N, Medicare exemption, MyGov account status.

---

## Applicability Flow

Most DOCUMENT items are conditional — they only apply if the user says YES to a related question:

```
Annual questionnaire email (once per FY)
  → User clicks YES/NO per question
  → ref.tax_checklist_responses updated
  → mart.vw_checklist_completeness re-evaluates applicable items
  → Metabase % complete reflects updated scope
```

Some DOCUMENT items are `always_required = true` (e.g., PAYG payment summary, tax agent fees) and are always in scope regardless of questionnaire.

---

## Seed Data — Checklist Items

### Section: Income

| item_name | item_type | always_required | applicability_question |
|---|---|---|---|
| Payment summary / PAYG from employer | DOCUMENT | YES | — |
| Bank interest statements | DOCUMENT | NO | Do you have interest income this year? |
| Managed fund Annual Tax Statement | DOCUMENT | NO | Did you receive income from a managed fund? |
| ETP / lump sum payout | DOCUMENT | NO | Did you finish employment or receive a lump sum payout? |
| Centrelink / government payments | DOCUMENT | NO | Did you receive Centrelink or pension payments? |
| Employee Share Scheme documents | DOCUMENT | NO | Are you involved in Employee Share Schemes? |
| Foreign income or overseas investments | DOCUMENT | NO | Did you earn foreign income or hold overseas investments? |
| Cryptocurrency annual tax summary (Koinly) | DOCUMENT | NO | Did you trade or hold cryptocurrency this year? |
| Business / trust / partnership distribution | DOCUMENT | NO | Did you receive a distribution from a business, trust, or partnership? |

### Section: Deductions

| item_name | item_type | always_required | applicability_question |
|---|---|---|---|
| Prior year tax agent fees invoice | DOCUMENT | YES | — |
| Motor vehicle logbook / odometer records | DOCUMENT | NO | Did you use your vehicle for work purposes? |
| Self-education receipts | DOCUMENT | NO | Did you have self-education expenses? |
| Home office records (hours log / timesheets) | DOCUMENT | NO | Did you work from home this year? |
| Donation receipts | DOCUMENT | NO | Did you make any tax-deductible donations? |
| Tools & equipment receipts | DOCUMENT | NO | Did you purchase work-related tools or equipment? |
| Work-related travel expenses | DOCUMENT | NO | Did you incur work-related travel costs? |
| Income protection insurance policy/statement | DOCUMENT | NO | Do you have income protection insurance outside your super? |
| Work-related assets purchased | DOCUMENT | NO | Did you purchase any work-related assets this year? |

### Section: Investments & CGT

| item_name | item_type | always_required | applicability_question |
|---|---|---|---|
| Share portfolio trading / dividend summary | DOCUMENT | NO | Do you hold shares or managed investments? |
| CGT documents (purchase + sale contracts) | DOCUMENT | NO | Did you sell any investments this year? |
| Cryptocurrency CGT report (Koinly) | DOCUMENT | NO | Did you trade or hold cryptocurrency this year? |

### Section: Super

| item_name | item_type | always_required | applicability_question |
|---|---|---|---|
| Superannuation annual statement | DOCUMENT | NO | Do you want to review super contributions for deductibility? |

### Section: Private Health & Medicare

| item_name | item_type | always_required | applicability_question |
|---|---|---|---|
| Private health insurance statement | DOCUMENT | NO | Do you have private health insurance? |

---

### RESPONSE items (stored for form pre-fill, not in % complete)

| item_name | response_format | notes |
|---|---|---|
| Do you have a MyGov account? | YES/NO | ATO correspondence goes to myGov inbox |
| HECS-HELP / StudyAssist debt? | YES/NO + loan_type | |
| Did you pay child support? | YES/NO + amount | |
| Spouse taxable income | NUMERIC | Only if not prepared by same agent |
| Home office: total hours worked from home | NUMERIC | Required for Fixed Rate Method |
| Home office: internet plan monthly cost | NUMERIC | Actual Cost Method |
| Home office: internet work-use % | NUMERIC | Actual Cost Method |
| Home office: mobile monthly cost | NUMERIC | Actual Cost Method |
| Home office: mobile work-use % | NUMERIC | Actual Cost Method |
| Vehicle: odometer 01/07/24 | NUMERIC | |
| Vehicle: odometer 30/06/25 | NUMERIC | |
| Vehicle: total work-related km | NUMERIC | |
| Vehicle: is it a zero-emission EV? | YES/NO | |
| Vehicle: is it a plug-in hybrid EV? | YES/NO | |
| Self-education: total study hours | NUMERIC | |
| Do you have a Power of Attorney (POA)? | YES/NO | Estate planning note only |
| Have you nominated a beneficiary for life insurance? | YES/NO | Estate planning note only |
| Have you chosen an Executor? | YES/NO | Estate planning note only |
| Medicare levy exemption (part or full year)? | YES/NO | |
| Are you a foreign resident or working holiday maker? | YES/NO | |

---

## Database Schema

### `ref.tax_checklist_items`
```sql
CREATE TABLE ref.tax_checklist_items (
    item_id         SERIAL PRIMARY KEY,
    section         TEXT NOT NULL,            -- 'Income', 'Deductions', 'Investments', 'Super', 'Health', 'Response'
    item_name       TEXT NOT NULL,
    description     TEXT,
    item_type       TEXT NOT NULL CHECK (item_type IN ('DOCUMENT', 'RESPONSE')),
    always_required BOOLEAN NOT NULL DEFAULT false,
    applicability_question TEXT,              -- The YES/NO question sent in the email
    category_tag    TEXT,                     -- Matches core.tax_documents.category_nme (DOCUMENT items only)
    response_format TEXT,                     -- 'YES_NO', 'NUMERIC', 'TEXT' (RESPONSE items only)
    sort_order      INTEGER,
    active          BOOLEAN NOT NULL DEFAULT true
);
```

### `ref.tax_checklist_responses`
```sql
CREATE TABLE ref.tax_checklist_responses (
    response_id     SERIAL PRIMARY KEY,
    item_id         INTEGER NOT NULL REFERENCES ref.tax_checklist_items(item_id),
    fy_year         SMALLINT NOT NULL,        -- e.g., 2025 for FY2024-25
    is_applicable   TEXT CHECK (is_applicable IN ('YES', 'NO', 'UNKNOWN')) DEFAULT 'UNKNOWN',
    response_value  TEXT,                     -- For RESPONSE items: free text / numeric / yes/no
    responded_at    TIMESTAMPTZ,
    source          TEXT DEFAULT 'EMAIL',     -- 'EMAIL' or 'DBEAVER'
    UNIQUE (item_id, fy_year)
);
```

### `mart.vw_checklist_completeness`
```sql
-- Joins items + responses + core.tax_documents
-- Only DOCUMENT items, only where applicable (always_required=true OR is_applicable='YES')
-- Satisfied = ≥1 CONFIRMED/AUTO_CONFIRMED doc matching category_tag for this FY
-- Output: section, item_name, is_applicable, is_satisfied, fy_year
-- Aggregate: % complete per section + overall
```

---

## Annual Email Questionnaire

### Trigger
- Manual trigger in n8n: `SEND_CHECKLIST_QUESTIONNAIRE` workflow
- Run once at start of each FY (early July), or on-demand

### Email format
```
Subject: Tax Checklist Setup — FY2025

Hi,

Please confirm which items apply to your FY2025 return.
Click YES or NO for each. You can re-answer any question at any time.

--- INCOME ---
Do you have interest income this year?           [YES] [NO]
Did you receive income from a managed fund?      [YES] [NO]
Did you trade or hold cryptocurrency this year?  [YES] [NO]
...

--- DEDUCTIONS ---
Did you use your vehicle for work purposes?      [YES] [NO]
...
```

Each YES/NO is an HMAC-signed link (same pattern as REVIEW_ACTION), encoding `item_id` + `fy_year` + `response`.

### Response Handler
`CHECKLIST_RESPONSE` workflow (webhook):
- Validates HMAC token
- Upserts `ref.tax_checklist_responses` with `is_applicable` = YES or NO
- Sends confirmation email: "Recorded: [Item name] → YES"

---

## Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `SEND_CHECKLIST_QUESTIONNAIRE` | Manual (once per FY) | Email all YES/NO questions with signed links |
| `CHECKLIST_RESPONSE` | Webhook | Record response, upsert ref.tax_checklist_responses |

---

## Metabase Dashboard

### Card: Overall % Complete (FY2025)
- Single number: satisfied / applicable DOCUMENT items
- Colour: red < 50%, amber 50-79%, green ≥ 80%

### Card: % Complete by Section
- Bar chart: Income, Deductions, Investments, Health, Super
- Each bar shows satisfied/applicable count

### Card: Outstanding Documents
- List view: item_name, section, days_since_fy_start
- Filtered to applicable + not satisfied

### Card: RESPONSE values (for reference)
- Table: item_name, response_value
- Shows captured pre-fill data (odometer, home office hours, etc.)

---

## Business Rules

- `% complete` = DOCUMENT items only where (`always_required = true` OR `is_applicable = 'YES'`) AND `response_value` for RESPONSE items is NOT included in % calculation
- A DOCUMENT item is **satisfied** when `core.tax_documents` has ≥1 row where `category_nme = category_tag` AND `fy_year = target_fy` AND `review_status IN ('CONFIRMED', 'AUTO_CONFIRMED')`
- Items with `is_applicable = 'UNKNOWN'` (questionnaire not yet answered): treated as NOT applicable for % complete (conservative — don't inflate the denominator)
- `always_required` items are always in the denominator regardless of questionnaire state
- Re-answering is allowed: webhook upserts on `(item_id, fy_year)` conflict

---

## Acceptance Criteria

- Given FY2025 questionnaire sent, when user clicks YES on "cryptocurrency", then `ref.tax_checklist_responses` has `is_applicable='YES'` for that item+FY
- Given crypto Koinly report lands in `core.tax_documents` with `category_nme='Investments - Cryptocurrency'` and `review_status='CONFIRMED'`, then the crypto checklist item shows as satisfied in the mart view
- Given 0 questionnaire responses, then `% complete` = confirmed always_required items / total always_required items
- Given all applicable items satisfied, then overall % = 100%
- Given a RESPONSE item (home office hours), it does NOT appear in % complete numerator or denominator

---

## Implementation Order

1. DDL: `ref.tax_checklist_items` + `ref.tax_checklist_responses`
2. Seed: insert all checklist items from docs/tax_agent/Client Checklist - Individual 2025.doc
3. Seed: insert FY2025 UNKNOWN responses for all items (so upsert works cleanly)
4. Build: `mart.vw_checklist_completeness`
5. Build: `SEND_CHECKLIST_QUESTIONNAIRE` workflow
6. Build: `CHECKLIST_RESPONSE` webhook workflow
7. Metabase: 4 dashboard cards

---

## Related Specs
- [001-database-schema.md](001-database-schema.md) — ref and mart schema conventions
- [004-metabase-portal.md](004-metabase-portal.md) — dashboard home
- [005-gmail-review-bot.md](005-gmail-review-bot.md) — HMAC token pattern reused here

## Open Questions
- [ ] Should UNKNOWN items (not yet answered) be shown on the Metabase dashboard separately, so the user knows to run the questionnaire?
- [ ] For items where category_tag may match multiple docs (e.g., multiple payslips), is one confirmed doc sufficient, or should there be a minimum count?
- [ ] Should the questionnaire re-send with current answers pre-filled on subsequent runs (for review), or always send blank?
