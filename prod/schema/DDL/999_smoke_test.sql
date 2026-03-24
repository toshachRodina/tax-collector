-- =============================================================================
-- 999_smoke_test.sql — Post-provisioning smoke test
-- Run as taxcollectorusr after all 001–006 DDL files complete.
-- All queries should return the expected row counts noted in comments.
-- =============================================================================

\c taxcollectordb
SET search_path TO ctl, ref, landing, core, mart, public;

\echo '--- SMOKE TEST START ---'

-- 1. All 5 schemas exist
\echo '1. Schemas'
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN ('ctl','ref','landing','core','mart')
ORDER BY schema_name;
-- Expected: 5 rows

-- 2. All base tables exist
\echo '2. Tables'
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('ctl','ref','landing','core')
  AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name;
-- Expected: 15 tables
-- ctl: budget_targets, ctrl_vars, process_log, statement_watermark
-- ref: accounts, fy_periods, statement_providers, tax_categories, transaction_categories
-- landing: financial_transactions, share_transactions, tax_documents
-- core: financial_transactions, share_transactions, tax_documents

-- 3. All mart views exist
\echo '3. Mart views'
SELECT table_name
FROM information_schema.views
WHERE table_schema = 'mart'
ORDER BY table_name;
-- Expected: 6 rows
-- vw_anomalies, vw_fy_cashflow, vw_monthly_spending, vw_savings_rate,
-- vw_spending_by_category, vw_tax_documents, vw_tax_summary

-- 4. Seed data counts
\echo '4. Seed data'
SELECT COUNT(*) AS fy_count              FROM ref.fy_periods;           -- Expected: 4
SELECT COUNT(*) AS tax_cat_count         FROM ref.tax_categories;       -- Expected: 19
SELECT COUNT(*) AS txn_cat_count         FROM ref.transaction_categories; -- Expected: ~43
SELECT COUNT(*) AS provider_count        FROM ref.statement_providers;  -- Expected: 3
SELECT COUNT(*) AS account_count         FROM ref.accounts;             -- Expected: 5

-- 5. Current FY
\echo '5. Current FY'
SELECT fy_label, start_date, end_date
FROM ref.fy_periods
WHERE is_current = TRUE;
-- Expected: FY2025 | 2024-07-01 | 2025-06-30

-- 6. All deductible tax categories
\echo '6. Deductible tax categories'
SELECT category_nme, ato_reference
FROM ref.tax_categories
WHERE is_deductible = TRUE
ORDER BY sort_order;
-- Expected: 8 rows (WFH categories, tech, software, professional dev, memberships, income protection)

-- 7. process_log RETURNING works
\echo '7. process_log insert with RETURNING'
INSERT INTO ctl.process_log (workflow_nme, status)
VALUES ('SMOKE_TEST', 'SUCCESS')
RETURNING batch_id, workflow_nme, status;
-- Expected: returns a batch_id integer

-- 8. Mart views query without error (empty DB = 0 rows, no errors)
\echo '8. Mart views return without error'
SELECT COUNT(*) AS doc_count        FROM mart.vw_tax_documents;
SELECT COUNT(*) AS summary_count    FROM mart.vw_tax_summary;
SELECT COUNT(*) AS monthly_count    FROM mart.vw_monthly_spending;
SELECT COUNT(*) AS savings_count    FROM mart.vw_savings_rate;
SELECT COUNT(*) AS anomaly_count    FROM mart.vw_anomalies;
SELECT COUNT(*) AS cashflow_count   FROM mart.vw_fy_cashflow;
-- Expected: all 0 (empty DB) with no errors

-- 9. Unique constraint on dedup_hash
\echo '9. Dedup hash constraint'
DO $$
DECLARE
    v_batch_id INTEGER;
    v_account_id INTEGER;
BEGIN
    -- Get a valid batch_id and account_id for test
    SELECT batch_id INTO v_batch_id FROM ctl.process_log WHERE workflow_nme = 'SMOKE_TEST' LIMIT 1;
    SELECT account_id INTO v_account_id FROM ref.accounts LIMIT 1;

    -- First insert
    INSERT INTO core.financial_transactions
        (account_id, txn_date, amount, description_raw, dedup_hash, batch_id)
    VALUES (v_account_id, '2025-01-15', -50.00, 'TEST TRANSACTION', 'SMOKE_TEST_HASH_001', v_batch_id);

    -- Second insert with same hash should fail
    BEGIN
        INSERT INTO core.financial_transactions
            (account_id, txn_date, amount, description_raw, dedup_hash, batch_id)
        VALUES (v_account_id, '2025-01-15', -50.00, 'TEST TRANSACTION', 'SMOKE_TEST_HASH_001', v_batch_id);
        RAISE EXCEPTION 'FAIL: Duplicate dedup_hash was not rejected!';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'PASS: Duplicate dedup_hash correctly rejected.';
    END;
END;
$$;

-- 10. Clean up smoke test data
\echo '10. Cleanup'
DELETE FROM core.financial_transactions WHERE dedup_hash = 'SMOKE_TEST_HASH_001';
DELETE FROM ctl.process_log WHERE workflow_nme = 'SMOKE_TEST';

\echo '--- SMOKE TEST COMPLETE ---'
\echo 'If you see no FAIL messages above, the schema is ready.'
