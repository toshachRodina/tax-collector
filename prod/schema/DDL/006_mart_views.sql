-- =============================================================================
-- 006_mart_views.sql — Analytical mart views (read-only)
-- Run as taxcollectorusr against taxcollectordb
-- Idempotent: uses CREATE OR REPLACE VIEW
-- No data stored here — all views are computed on read.
-- =============================================================================

\c taxcollectordb
SET search_path TO mart, public;

-- ---------------------------------------------------------------------------
-- mart.vw_tax_documents
-- Enriched tax document view with category names and FY label.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_tax_documents AS
SELECT
    d.doc_id,
    d.source_type,
    d.subject,
    d.sender_email,
    d.received_at,
    f.fy_label,
    f.fy_year,
    c.category_nme          AS tax_category,
    c.category_grp          AS tax_category_group,
    c.ato_reference,
    d.is_deductible,
    d.deductible_amount,
    d.confidence_score,
    d.review_status,
    d.reviewer_notes,
    d.file_name,
    d.file_ext,
    d.content_preview,
    d.created_at,
    d.updated_at
FROM core.tax_documents d
LEFT JOIN ref.fy_periods f      ON d.fy_year = f.fy_year
LEFT JOIN ref.tax_categories c  ON d.tax_category_id = c.category_id;

COMMENT ON VIEW mart.vw_tax_documents IS
    'Enriched view of all tax documents with category and FY labels. '
    'Use this in the review UI and for report generation.';

-- ---------------------------------------------------------------------------
-- mart.vw_tax_summary
-- FY tax summary by category — used for accountant handoff report.
-- Only includes PENDING or CONFIRMED documents.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_tax_summary AS
SELECT
    f.fy_label,
    f.fy_year,
    c.category_grp          AS tax_category_group,
    c.category_nme          AS tax_category,
    c.ato_reference,
    c.sort_order,
    COUNT(d.doc_id)         AS document_count,
    SUM(d.deductible_amount) AS total_deductible_amt,
    MIN(d.received_at)      AS earliest_doc,
    MAX(d.received_at)      AS latest_doc
FROM core.tax_documents d
JOIN ref.fy_periods f       ON d.fy_year = f.fy_year
JOIN ref.tax_categories c   ON d.tax_category_id = c.category_id
WHERE d.is_deductible = TRUE
  AND d.review_status IN ('PENDING', 'CONFIRMED')
GROUP BY f.fy_label, f.fy_year, c.category_grp, c.category_nme, c.ato_reference, c.sort_order
ORDER BY f.fy_year DESC, c.sort_order;

COMMENT ON VIEW mart.vw_tax_summary IS
    'FY deductible expense summary grouped by ATO category. '
    'Excludes REJECTED documents. Used for accountant handoff report.';

-- ---------------------------------------------------------------------------
-- mart.vw_monthly_spending
-- Monthly spend by category across all accounts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_monthly_spending AS
SELECT
    t.account_id,
    a.account_nme,
    a.provider,
    DATE_TRUNC('month', t.txn_date)::DATE   AS month_start,
    TO_CHAR(t.txn_date, 'YYYY-MM')          AS month_label,
    EXTRACT(YEAR FROM t.txn_date)::SMALLINT AS txn_year,
    EXTRACT(MONTH FROM t.txn_date)::SMALLINT AS txn_month,
    c.category_nme,
    c.subcategory_nme,
    c.is_income,
    c.is_deductible,
    SUM(t.amount)                            AS total_amount,
    COUNT(*)                                 AS txn_count,
    bt.budget_amount
FROM core.financial_transactions t
JOIN ref.accounts a                 ON t.account_id = a.account_id
LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
LEFT JOIN ctl.budget_targets bt     ON  bt.category_id = t.category_id
                                    AND bt.fy_year = CASE
                                            WHEN EXTRACT(MONTH FROM t.txn_date) >= 7
                                            THEN EXTRACT(YEAR FROM t.txn_date)::SMALLINT + 1
                                            ELSE EXTRACT(YEAR FROM t.txn_date)::SMALLINT
                                        END
                                    AND bt.month_num = EXTRACT(MONTH FROM t.txn_date)::SMALLINT
GROUP BY
    t.account_id, a.account_nme, a.provider,
    DATE_TRUNC('month', t.txn_date), TO_CHAR(t.txn_date, 'YYYY-MM'),
    EXTRACT(YEAR FROM t.txn_date), EXTRACT(MONTH FROM t.txn_date),
    c.category_nme, c.subcategory_nme, c.is_income, c.is_deductible,
    bt.budget_amount
ORDER BY month_start DESC, c.category_nme;

COMMENT ON VIEW mart.vw_monthly_spending IS
    'Monthly spend by category including budget targets where set. '
    'Negative total_amount = money out (expense). Positive = money in (income/credit).';

-- ---------------------------------------------------------------------------
-- mart.vw_spending_by_category
-- All-time spend aggregated by category — for category breakdown report.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_spending_by_category AS
SELECT
    c.category_nme,
    c.subcategory_nme,
    c.is_income,
    c.is_deductible,
    COUNT(*)                        AS txn_count,
    SUM(t.amount)                   AS total_amount,
    AVG(t.amount)                   AS avg_amount,
    MIN(t.txn_date)                 AS first_txn_date,
    MAX(t.txn_date)                 AS last_txn_date
FROM core.financial_transactions t
LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
GROUP BY c.category_nme, c.subcategory_nme, c.is_income, c.is_deductible
ORDER BY SUM(ABS(t.amount)) DESC;

COMMENT ON VIEW mart.vw_spending_by_category IS
    'All-time transaction aggregates by category. Ordered by total absolute amount descending.';

-- ---------------------------------------------------------------------------
-- mart.vw_savings_rate
-- Monthly income vs. spend → savings rate trend.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_savings_rate AS
WITH monthly_totals AS (
    SELECT
        TO_CHAR(t.txn_date, 'YYYY-MM')          AS month_label,
        DATE_TRUNC('month', t.txn_date)::DATE   AS month_start,
        SUM(CASE WHEN c.is_income = TRUE  THEN t.amount        ELSE 0 END) AS total_income,
        SUM(CASE WHEN c.is_income = FALSE THEN ABS(t.amount)   ELSE 0 END) AS total_spend
    FROM core.financial_transactions t
    LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
    GROUP BY TO_CHAR(t.txn_date, 'YYYY-MM'), DATE_TRUNC('month', t.txn_date)
)
SELECT
    month_label,
    month_start,
    ROUND(total_income, 2)                  AS total_income,
    ROUND(total_spend, 2)                   AS total_spend,
    ROUND(total_income - total_spend, 2)    AS net_savings,
    CASE
        WHEN total_income > 0
        THEN ROUND((total_income - total_spend) / total_income * 100, 1)
        ELSE NULL
    END                                     AS savings_rate_pct
FROM monthly_totals
ORDER BY month_start DESC;

COMMENT ON VIEW mart.vw_savings_rate IS
    'Monthly income vs. spend and savings rate percentage. '
    'Requires transactions to be categorised with is_income flags set correctly.';

-- ---------------------------------------------------------------------------
-- mart.vw_anomalies
-- Transactions flagged as anomalies by the classifier.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_anomalies AS
SELECT
    t.txn_id,
    t.account_id,
    a.account_nme,
    a.provider,
    t.txn_date,
    t.amount,
    t.description_clean,
    t.description_raw,
    c.category_nme,
    c.subcategory_nme,
    t.anomaly_reason,
    t.review_status,
    t.created_at
FROM core.financial_transactions t
JOIN ref.accounts a                 ON t.account_id = a.account_id
LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
WHERE t.is_anomaly = TRUE
ORDER BY t.txn_date DESC;

COMMENT ON VIEW mart.vw_anomalies IS
    'All transactions flagged as anomalies. '
    'Review NEEDS_REVIEW status rows in the frontend UI.';

-- ---------------------------------------------------------------------------
-- mart.vw_fy_cashflow
-- Tax year cash flow summary — total income, spend, and deductibles per FY.
-- Feeds the tax year cash flow report (Financial Health feature priority #5).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_fy_cashflow AS
SELECT
    CASE
        WHEN EXTRACT(MONTH FROM t.txn_date) >= 7
        THEN EXTRACT(YEAR FROM t.txn_date)::SMALLINT + 1
        ELSE EXTRACT(YEAR FROM t.txn_date)::SMALLINT
    END                                     AS fy_year,
    fp.fy_label,
    SUM(CASE WHEN c.is_income = TRUE  THEN t.amount      ELSE 0 END) AS total_income,
    SUM(CASE WHEN c.is_income = FALSE THEN ABS(t.amount) ELSE 0 END) AS total_spend,
    SUM(CASE WHEN t.is_deductible = TRUE THEN t.deductible_amount ELSE 0 END) AS total_deductible
FROM core.financial_transactions t
LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
LEFT JOIN ref.fy_periods fp ON fp.fy_year = CASE
        WHEN EXTRACT(MONTH FROM t.txn_date) >= 7
        THEN EXTRACT(YEAR FROM t.txn_date)::SMALLINT + 1
        ELSE EXTRACT(YEAR FROM t.txn_date)::SMALLINT
    END
GROUP BY
    CASE
        WHEN EXTRACT(MONTH FROM t.txn_date) >= 7
        THEN EXTRACT(YEAR FROM t.txn_date)::SMALLINT + 1
        ELSE EXTRACT(YEAR FROM t.txn_date)::SMALLINT
    END,
    fp.fy_label
ORDER BY fy_year DESC;

COMMENT ON VIEW mart.vw_fy_cashflow IS
    'Tax year (July–June) cash flow summary. '
    'Used for the tax year cash flow report — synergy with Pillar 1 tax summary.';

\echo '✓ 006_mart_views.sql complete'
