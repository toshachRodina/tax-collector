# Spec 004 — Metabase Tax Portal

## Status: IN PROGRESS
**Priority**: 1 of 8
**Session**: 2026-04-06

---

## Goal

A multi-dashboard Metabase portal that is the single read-only window into all tax and financial health data. Navigation between dashboards should feel like tabs in an integrated app. Write-back (approve/reject decisions) is handled by the Telegram bot (Spec 005) — Metabase is display only.

---

## DB Connection (one-time setup)

| Field    | Value             |
|----------|-------------------|
| Host     | `192.168.0.250`   |
| Port     | `5432`            |
| Database | `taxcollectordb`  |
| User     | `metabase_ro`     |
| Password | stored in 1Password / saved locally |

Connection steps in Metabase:
1. Settings → Databases → Add database → PostgreSQL
2. Fill in the fields above
3. Name it: **Tax Collector DB**
4. Toggle OFF "Sync all table metadata" for now (keep it fast)
5. Click Save → wait for sync to complete

---

## Collection Structure

All content lives in a Metabase Collection:

```
Tax Portal (collection)
├── 🏠 Home               ← landing dashboard with key metrics + nav links
├── 📋 Review Queue       ← NEEDS_REVIEW records awaiting decision
├── 📊 FY Summary         ← confirmed deductions by category and year
├── 💰 Financial Health   ← bank transactions, cash flow (placeholder until Spec 007)
└── 📈 Investments        ← CGT events, shares, dividends
```

Each dashboard includes a **navigation bar** built from Text cards at the top — markdown links to each other dashboard. This simulates tabbed navigation.

---

## Dashboard Specs

### 🏠 Home

Purpose: At-a-glance health check. First thing you see each session.

| Card | Type | Source |
|------|------|--------|
| Records awaiting review | Metric (count) | `mart.vw_tax_documents` WHERE `review_status = 'NEEDS_REVIEW'` |
| Total confirmed deductions (current FY) | Metric (sum `total_amount`) | `mart.vw_tax_documents` WHERE `review_status = 'CONFIRMED'` AND `fy_year = 2025` |
| Total confirmed records (current FY) | Metric (count) | Same filter |
| Records by status | Pie or bar chart | `mart.vw_tax_documents` GROUP BY `review_status` |
| Nav bar | Text card | Links to Review Queue, FY Summary, Financial Health, Investments |

---

### 📋 Review Queue

Purpose: All NEEDS_REVIEW records — what requires human attention. Currently empty (all records reviewed) but will fill on each new Gmail run.

| Card | Type | Source |
|------|------|--------|
| Awaiting review count | Metric | `mart.vw_tax_documents` WHERE `review_status = 'NEEDS_REVIEW'` |
| Review queue table | Table | `mart.vw_tax_documents` WHERE `review_status = 'NEEDS_REVIEW'` |
| Table columns | — | `doc_id`, `supplier_name`, `subject`, `tax_category`, `confidence_score`, `total_amount`, `document_date`, `fy_label`, `reviewer_notes` |
| Filter | Dashboard filter | `fy_year` (dropdown) |
| Nav bar | Text card | Links to other dashboards |

Notes:
- Sort by `confidence_score` ASC (lowest confidence = most uncertain = review first)
- `doc_id` should link to the single-record view in core (or just show it for DBeaver lookup)
- Include `AUTO_CONFIRMED` in a second table as a spot-check section

---

### 📊 FY Summary

Purpose: The "tax pack" view — what will go to your accountant.

| Card | Type | Source |
|------|------|--------|
| Total deductions | Metric (SUM `total_amount`) | CONFIRMED only, selected FY |
| Confirmed record count | Metric | CONFIRMED, selected FY |
| Categories covered | Metric (distinct count) | CONFIRMED, selected FY |
| Deductions by category | Horizontal bar chart | `mart.vw_tax_summary` filtered by FY |
| Category breakdown table | Table | `mart.vw_tax_summary` — category, count, total amount |
| Year-on-year comparison | Line/bar chart | `mart.vw_tax_summary` all FY years, SUM by year |
| Filter | Dashboard filter | `fy_year` (dropdown, default current FY) |
| Nav bar | Text card | Links to other dashboards |

---

### 💰 Financial Health

Purpose: Bank transaction overview. **Placeholder until Spec 007 (bank statement pipeline) is built.**

Content for now:
- Text card explaining this will show cash flow, savings rate, and spending by category once bank statements are connected
- Single metric: "Bank records loaded: 0"

When Spec 007 is live, add:
- Monthly cash flow (income vs expenses)
- Spending by category
- Savings rate trend
- Source views: `mart.vw_fy_cashflow`, `mart.vw_monthly_spending`, `mart.vw_spending_by_category`, `mart.vw_savings_rate`

---

### 📈 Investments

Purpose: CGT events, share dividends, rental/property documents.

| Card | Type | Source |
|------|------|--------|
| Investment documents table | Table | `mart.vw_tax_documents` WHERE `tax_category_group = 'Income'` OR `tax_category IN ('Share Sale / CGT Event', 'Dividend Statement', 'Property Depreciation Schedule')` |
| Filter | Dashboard filter | `fy_year` |
| Nav bar | Text card | Links to other dashboards |

---

## Navigation Bar Template (Text card)

Use this markdown in a Text card at the top of every dashboard. Replace `[DASHBOARD_ID]` with actual Metabase dashboard IDs after creation.

```markdown
**Tax Portal** &nbsp;|&nbsp; [🏠 Home](/dashboard/HOME_ID) &nbsp;|&nbsp; [📋 Review Queue](/dashboard/QUEUE_ID) &nbsp;|&nbsp; [📊 FY Summary](/dashboard/FY_ID) &nbsp;|&nbsp; [💰 Financial Health](/dashboard/FH_ID) &nbsp;|&nbsp; [📈 Investments](/dashboard/INV_ID)
```

---

## Done Criteria

- [ ] DB connection established in Metabase (Tax Collector DB)
- [ ] Collection "Tax Portal" created
- [ ] Home dashboard live with 4 metric cards + nav bar
- [ ] Review Queue dashboard live with sortable table + FY filter
- [ ] FY Summary dashboard live with bar chart + year-on-year comparison
- [ ] Financial Health dashboard live (placeholder state)
- [ ] Investments dashboard live
- [ ] Nav bar working across all dashboards
- [ ] All dashboards bookmarked / pinned in Metabase

---

## Out of Scope (This Spec)

- Write-back / approval buttons (→ Spec 005 Telegram bot)
- Bank transaction charts (→ Spec 007)
- Tax checklist completeness meter (→ Spec 008)
- Embedding Metabase in an external portal
