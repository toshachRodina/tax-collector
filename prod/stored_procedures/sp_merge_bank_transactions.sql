-- =============================================================================
-- sp_merge_bank_transactions.sql
-- Tax Collector — Merge landing.bank_transactions → core.bank_transactions
--
-- Idempotent UPSERT. Safe to re-run.
-- Processes all landing rows not yet present in core (dedup by row_hash).
--
-- Purpose:
--   1. Promote raw landing rows to normalised core table
--   2. Resolve fy_year, account_label, tax_category_id
--   3. Set has_matching_document by cross-checking core.tax_documents
--   4. Assign review_status:
--        Interest rows      → CONFIRMED  (declare as ATO income, no receipt expected)
--        Flagged categories → NEEDS_REVIEW (check for matching document)
--        Everything else    → PENDING
--
-- Called by: n8n LOAD_CORE_BANK workflow (alternative to inline SQL merge node)
-- Run as: taxcollectorusr
-- =============================================================================

CREATE OR REPLACE PROCEDURE core.sp_merge_bank_transactions(
    p_batch_id  INTEGER DEFAULT NULL   -- NULL = process all unmerged rows
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_merged   INTEGER := 0;
    v_skipped  INTEGER := 0;
BEGIN

    -- -------------------------------------------------------------------------
    -- Step 1: INSERT new landing rows into core (dedup via ON CONFLICT DO NOTHING)
    -- -------------------------------------------------------------------------
    WITH new_rows AS (
        SELECT
            l.account_number,
            CASE
                WHEN l.source_file ILIKE '%VISA%'     THEN 'VISA'
                WHEN l.source_file ILIKE '%Savings1%' THEN 'Savings1'
                WHEN l.source_file ILIKE '%Savings2%' THEN 'Savings2'
                ELSE 'Unknown'
            END                                             AS account_label,
            l.txn_date,
            f.fy_year,
            l.amount,
            l.transaction_type,
            l.transaction_details,
            l.merchant_name,
            l.nab_category,
            -- Tax category ID lookup
            CASE l.nab_category
                WHEN 'Subscriptions'       THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Software & Subscriptions' LIMIT 1)
                WHEN 'Education'           THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Professional Development'  LIMIT 1)
                WHEN 'Tax & Accountant'    THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Tax Agent Fees'            LIMIT 1)
                WHEN 'Donations'           THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Donations'                 LIMIT 1)
                WHEN 'Transport'           THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Motor Vehicle / Logbook'   LIMIT 1)
                WHEN 'Electronic Shopping' THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Technology Equipment'      LIMIT 1)
                WHEN 'Health & Medical'    THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Private Health Insurance'  LIMIT 1)
                WHEN 'Interest'            THEN (SELECT category_id FROM ref.tax_categories WHERE category_nme = 'Bank Interest'             LIMIT 1)
                ELSE NULL
            END                                             AS tax_category_id,
            -- is_potentially_deductible (retained column; Interest = FALSE, flagged = TRUE)
            CASE l.nab_category
                WHEN 'Interest' THEN FALSE
                WHEN 'Subscriptions','Education','Tax & Accountant','Donations',
                     'Business Services','Transport','Electronic Shopping','Health & Medical' THEN TRUE
                ELSE FALSE
            END                                             AS is_potentially_deductible,
            -- deductible_notes
            CASE l.nab_category
                WHEN 'Subscriptions'       THEN 'Check for matching receipt in documents'
                WHEN 'Education'           THEN 'Check for receipt or enrolment letter in documents'
                WHEN 'Tax & Accountant'    THEN 'Check for invoice in documents'
                WHEN 'Donations'           THEN 'Check for receipt in documents'
                WHEN 'Business Services'   THEN 'Check for invoice in documents'
                WHEN 'Transport'           THEN 'Check for logbook or receipt in documents'
                WHEN 'Electronic Shopping' THEN 'Check for matching receipt in documents'
                WHEN 'Health & Medical'    THEN 'Check for annual statement in documents'
                WHEN 'Interest'            THEN 'Declare as ATO income — no receipt expected'
                ELSE NULL
            END                                             AS deductible_notes,
            -- has_matching_document: cross-check core.tax_documents for supplier + date proximity
            EXISTS (
                SELECT 1 FROM core.tax_documents d
                WHERE d.fy_year = f.fy_year
                  AND (
                      (l.merchant_name IS NOT NULL
                       AND d.supplier_name ILIKE '%' || l.merchant_name || '%')
                   OR (l.transaction_details IS NOT NULL
                       AND d.supplier_name ILIKE '%' || split_part(l.transaction_details, ' ', 1) || '%')
                  )
                  AND (d.document_date IS NULL
                       OR ABS(EXTRACT(DAY FROM (d.document_date - l.txn_date))) <= 60)
            )                                               AS has_matching_document,
            -- review_status
            CASE
                WHEN l.nab_category = 'Interest' THEN 'CONFIRMED'
                WHEN l.nab_category IN (
                    'Subscriptions','Education','Tax & Accountant','Donations',
                    'Business Services','Transport','Electronic Shopping','Health & Medical'
                ) THEN 'NEEDS_REVIEW'
                ELSE 'PENDING'
            END                                             AS review_status,
            l.row_hash,
            l.batch_id                                      AS landing_batch_id
        FROM landing.bank_transactions l
        LEFT JOIN ref.fy_periods f
            ON l.txn_date BETWEEN f.start_date AND f.end_date
        LEFT JOIN core.bank_transactions c
            ON l.row_hash = c.row_hash
        WHERE c.row_hash IS NULL
          AND (p_batch_id IS NULL OR l.batch_id = p_batch_id)
    )
    INSERT INTO core.bank_transactions (
        account_number, account_label, txn_date, fy_year,
        amount, transaction_type, transaction_details, merchant_name,
        nab_category, tax_category_id, is_potentially_deductible,
        deductible_notes, has_matching_document, review_status,
        row_hash, batch_id
    )
    SELECT
        account_number, account_label, txn_date, fy_year,
        amount, transaction_type, transaction_details, merchant_name,
        nab_category, tax_category_id, is_potentially_deductible,
        deductible_notes, has_matching_document, review_status,
        row_hash, landing_batch_id
    FROM new_rows
    ON CONFLICT (row_hash) DO NOTHING;

    GET DIAGNOSTICS v_merged = ROW_COUNT;

    -- -------------------------------------------------------------------------
    -- Step 2: Re-evaluate has_matching_document for existing NEEDS_REVIEW rows.
    --         As new documents are scanned, previously-missing receipts may now
    --         exist. Update all NEEDS_REVIEW rows so the mart view stays current.
    -- -------------------------------------------------------------------------
    UPDATE core.bank_transactions t
    SET has_matching_document = EXISTS (
            SELECT 1 FROM core.tax_documents d
            WHERE d.fy_year = t.fy_year
              AND (
                  (t.merchant_name IS NOT NULL
                   AND d.supplier_name ILIKE '%' || t.merchant_name || '%')
               OR (t.transaction_details IS NOT NULL
                   AND d.supplier_name ILIKE '%' || split_part(t.transaction_details, ' ', 1) || '%')
              )
              AND (d.document_date IS NULL
                   OR ABS(EXTRACT(DAY FROM (d.document_date - t.txn_date))) <= 60)
        ),
        updated_at = NOW()
    WHERE t.review_status = 'NEEDS_REVIEW'
      AND t.has_matching_document = FALSE;

    GET DIAGNOSTICS v_skipped = ROW_COUNT;

    RAISE NOTICE 'sp_merge_bank_transactions: inserted=%, re-evaluated=%', v_merged, v_skipped;

END;
$$;

COMMENT ON PROCEDURE core.sp_merge_bank_transactions IS
    'Promotes landing.bank_transactions rows to core.bank_transactions. '
    'Resolves fy_year, account_label, tax_category_id, has_matching_document, review_status. '
    'Idempotent — safe to re-run. Interest rows auto-CONFIRMED. '
    'Also re-evaluates has_matching_document for existing NEEDS_REVIEW rows '
    'so the mart.vw_missing_receipt_indicators view stays current as new documents arrive.';
