-- =============================================================================
-- 010_bank_transactions.sql — Bank transaction landing and core tables
-- Run as taxcollectorusr against taxcollectordb
-- Idempotent: safe to re-run
-- Landing table is APPEND-ONLY. Never UPDATE or DELETE rows here.
-- =============================================================================

\c taxcollectordb

-- ---------------------------------------------------------------------------
-- 1. landing.bank_transactions
--    Raw CSV rows from NAB bank statement drops.
--    Dedup key: row_hash (SHA-256 of account_number + txn_date + amount + details)
-- ---------------------------------------------------------------------------
SET search_path TO landing, public;

CREATE TABLE IF NOT EXISTS landing.bank_transactions (
    txn_landing_id      SERIAL          PRIMARY KEY,
    batch_id            INTEGER         NOT NULL REFERENCES ctl.process_log(batch_id),
    source_file         VARCHAR(500)    NOT NULL,
    account_number      VARCHAR(100),
    txn_date            DATE,
    amount              NUMERIC(10,2),
    transaction_type    VARCHAR(100),
    transaction_details VARCHAR(500),
    balance             NUMERIC(10,2),
    nab_category        VARCHAR(200),
    merchant_name       VARCHAR(500),
    processed_on        DATE,
    row_hash            VARCHAR(64),
    loaded_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_landing_bank_txn_hash UNIQUE (row_hash)
);

CREATE INDEX IF NOT EXISTS idx_landing_bank_txn_batch
    ON landing.bank_transactions(batch_id);
CREATE INDEX IF NOT EXISTS idx_landing_bank_txn_source
    ON landing.bank_transactions(source_file);
CREATE INDEX IF NOT EXISTS idx_landing_bank_txn_date
    ON landing.bank_transactions(txn_date);

COMMENT ON TABLE landing.bank_transactions IS
    'Raw CSV rows from NAB bank statement drops. Append-only. '
    'row_hash = SHA-256(account_number || txn_date || amount || transaction_details). '
    'Merged into core.bank_transactions via LOAD_CORE_BANK workflow.';

-- ---------------------------------------------------------------------------
-- 2. core.bank_transactions
--    Normalised, classified bank transactions.
--    Dedup key: row_hash (same hash as landing, stored for cross-table dedup)
-- ---------------------------------------------------------------------------
SET search_path TO core, public;

CREATE TABLE IF NOT EXISTS core.bank_transactions (
    txn_id                  SERIAL          PRIMARY KEY,
    account_number          VARCHAR(100)    NOT NULL,
    account_label           VARCHAR(100),               -- 'Savings1', 'Savings2', 'VISA'
    txn_date                DATE            NOT NULL,
    fy_year                 SMALLINT        REFERENCES ref.fy_periods(fy_year),
    amount                  NUMERIC(10,2)   NOT NULL,
    transaction_type        VARCHAR(100),
    transaction_details     VARCHAR(500),
    merchant_name           VARCHAR(500),
    nab_category            VARCHAR(200),
    tax_category_id         INTEGER         REFERENCES ref.tax_categories(category_id),
    is_potentially_deductible BOOLEAN       NOT NULL DEFAULT FALSE,
    deductible_notes        VARCHAR(500),
    has_matching_document   BOOLEAN         NOT NULL DEFAULT FALSE,  -- TRUE if a doc exists in core.tax_documents for this transaction
    review_status           VARCHAR(20)     NOT NULL DEFAULT 'PENDING'
                            CHECK (review_status IN (
                                'PENDING','CONFIRMED','REJECTED','NEEDS_REVIEW')),
    row_hash                VARCHAR(64),
    batch_id                INTEGER         REFERENCES ctl.process_log(batch_id),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_core_bank_txn_hash UNIQUE (row_hash)
);

-- Idempotent: add has_matching_document if not already present (safe to re-run on existing DB)
ALTER TABLE core.bank_transactions
    ADD COLUMN IF NOT EXISTS has_matching_document BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_core_bank_txn_date
    ON core.bank_transactions(txn_date);
CREATE INDEX IF NOT EXISTS idx_core_bank_txn_fy_year
    ON core.bank_transactions(fy_year);
CREATE INDEX IF NOT EXISTS idx_core_bank_txn_review
    ON core.bank_transactions(review_status);
CREATE INDEX IF NOT EXISTS idx_core_bank_txn_deductible
    ON core.bank_transactions(is_potentially_deductible)
    WHERE is_potentially_deductible = TRUE;

COMMENT ON TABLE core.bank_transactions IS
    'Normalised bank transactions from NAB CSV imports. '
    'row_hash = SHA-256(account_number || txn_date || amount || transaction_details). '
    'Direct INSERT/UPDATE from application code is prohibited — use LOAD_CORE_BANK workflow.';

-- Trigger: auto-update updated_at on any UPDATE
-- Reuses core.set_updated_at() defined in 005_core_schema.sql
DROP TRIGGER IF EXISTS trg_bank_txn_updated_at ON core.bank_transactions;
CREATE TRIGGER trg_bank_txn_updated_at
    BEFORE UPDATE ON core.bank_transactions
    FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. mart.vw_bank_deductibles  (retained for backwards compatibility)
--    Transactions flagged as potentially tax-deductible.
-- ---------------------------------------------------------------------------
SET search_path TO mart, public;

CREATE OR REPLACE VIEW mart.vw_bank_deductibles AS
SELECT
    t.txn_id,
    t.account_label,
    t.txn_date,
    f.fy_year,
    f.fy_label,
    t.amount,
    t.merchant_name,
    t.nab_category,
    t.tax_category_id,
    c.category_nme          AS tax_category,
    t.deductible_notes,
    t.review_status
FROM core.bank_transactions t
LEFT JOIN ref.fy_periods f          ON t.fy_year = f.fy_year
LEFT JOIN ref.tax_categories c      ON t.tax_category_id = c.category_id
WHERE t.is_potentially_deductible = TRUE
ORDER BY t.txn_date DESC;

COMMENT ON VIEW mart.vw_bank_deductibles IS
    'Bank transactions flagged as potentially tax-deductible. Retained for backwards compatibility. '
    'Prefer mart.vw_bank_interest_income and mart.vw_missing_receipt_indicators for new queries.';

-- ---------------------------------------------------------------------------
-- 4. mart.vw_bank_interest_income
--    Interest income rows — must be declared to the ATO each FY.
--    These are the rows where the transaction IS the tax item
--    (no separate document exists; NAB statement is the source of truth).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW mart.vw_bank_interest_income AS
SELECT
    t.txn_id,
    t.account_label,
    t.account_number,
    t.txn_date,
    f.fy_year,
    f.fy_label,
    t.amount,
    t.transaction_details,
    t.merchant_name,
    t.review_status
FROM core.bank_transactions t
LEFT JOIN ref.fy_periods f ON t.fy_year = f.fy_year
WHERE t.nab_category = 'Interest'
ORDER BY t.fy_year DESC, t.txn_date DESC;

COMMENT ON VIEW mart.vw_bank_interest_income IS
    'Bank interest income lines by FY. '
    'These must be declared to the ATO — no separate document is expected. '
    'Sum amount per fy_year and include in income declarations.';

-- ---------------------------------------------------------------------------
-- 5. mart.vw_missing_receipt_indicators
--    Flagged transaction categories where no matching document exists in
--    core.tax_documents. These are GAP INDICATORS — the transaction shows
--    a purchase in a category that often has a deductible receipt, but no
--    receipt has been scanned into the system yet.
--    Action: locate and scan the corresponding receipt/statement.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW mart.vw_missing_receipt_indicators AS
SELECT
    t.txn_id,
    t.account_label,
    t.txn_date,
    f.fy_year,
    f.fy_label,
    t.amount,
    t.nab_category,
    t.merchant_name,
    t.transaction_details,
    t.deductible_notes      AS reason_flagged,
    t.has_matching_document,
    t.review_status
FROM core.bank_transactions t
LEFT JOIN ref.fy_periods f ON t.fy_year = f.fy_year
WHERE t.nab_category IN (
        'Subscriptions', 'Education', 'Tax & Accountant', 'Donations',
        'Business Services', 'Transport', 'Electronic Shopping', 'Health & Medical'
      )
  AND t.has_matching_document = FALSE
ORDER BY t.fy_year DESC, t.nab_category, t.txn_date DESC;

COMMENT ON VIEW mart.vw_missing_receipt_indicators IS
    'Transactions in categories that typically have a deductible receipt, '
    'where no matching document has been found in core.tax_documents. '
    'These are gap indicators — locate and scan the missing receipt/statement. '
    'Once the document is scanned and merged, has_matching_document updates on next LOAD_CORE_BANK run.';

\echo '✓ 010_bank_transactions.sql complete'
