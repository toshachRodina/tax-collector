-- =============================================================================
-- 002_ref_schema.sql — Reference / Lookup schema (tables only, no seed data)
-- Run as taxcollectorusr against taxcollectordb
-- Idempotent: safe to re-run
-- =============================================================================

\c taxcollectordb
SET search_path TO ref, public;

-- ---------------------------------------------------------------------------
-- ref.fy_periods
-- Australian financial year boundaries. July 1 – June 30.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.fy_periods (
    fy_year             SMALLINT PRIMARY KEY,
    fy_label            VARCHAR(20) NOT NULL,
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    lodgement_deadline  DATE NOT NULL,
    is_current          BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_fy_dates CHECK (end_date > start_date)
);

COMMENT ON TABLE ref.fy_periods IS
    'Australian financial year boundaries. July 1 to June 30. '
    'is_current = TRUE for the active FY. Only one row may be TRUE.';

-- Ensure only one is_current = TRUE
CREATE UNIQUE INDEX IF NOT EXISTS idx_fy_periods_current
    ON ref.fy_periods(is_current) WHERE is_current = TRUE;

-- ---------------------------------------------------------------------------
-- ref.tax_categories
-- Canonical ATO-aligned tax document categories.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.tax_categories (
    category_id     SERIAL PRIMARY KEY,
    category_nme    VARCHAR(100) NOT NULL UNIQUE,
    category_grp    VARCHAR(50) NOT NULL,
    description     TEXT,
    is_deductible   BOOLEAN NOT NULL DEFAULT FALSE,
    ato_reference   VARCHAR(200),
    sort_order      SMALLINT NOT NULL DEFAULT 99
);

CREATE INDEX IF NOT EXISTS idx_tax_categories_grp
    ON ref.tax_categories(category_grp);

COMMENT ON TABLE ref.tax_categories IS
    'ATO-aligned tax document categories. '
    'is_deductible flags deductible expense types.';

-- ---------------------------------------------------------------------------
-- ref.transaction_categories
-- Spending categories for financial health analysis.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.transaction_categories (
    category_id         SERIAL PRIMARY KEY,
    category_nme        VARCHAR(100) NOT NULL,
    subcategory_nme     VARCHAR(100),
    is_income           BOOLEAN NOT NULL DEFAULT FALSE,
    is_tax_relevant     BOOLEAN NOT NULL DEFAULT FALSE,
    is_deductible       BOOLEAN NOT NULL DEFAULT FALSE,
    description         TEXT,
    sort_order          SMALLINT NOT NULL DEFAULT 99
);

-- Expression-based unique index (can't use COALESCE in table-level UNIQUE constraint)
CREATE UNIQUE INDEX IF NOT EXISTS idx_txn_categories_unique
    ON ref.transaction_categories(category_nme, COALESCE(subcategory_nme, ''));

CREATE INDEX IF NOT EXISTS idx_txn_categories_nme
    ON ref.transaction_categories(category_nme);

COMMENT ON TABLE ref.transaction_categories IS
    'Spending categories for financial transaction classification.';

-- ---------------------------------------------------------------------------
-- ref.statement_providers
-- CSV column mapping config per financial provider.
-- Allows the ingestor to normalise different column layouts.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.statement_providers (
    provider_id     SERIAL PRIMARY KEY,
    provider_nme    VARCHAR(100) NOT NULL UNIQUE,
    date_col        VARCHAR(50) NOT NULL,
    date_format     VARCHAR(30) NOT NULL,
    amount_col      VARCHAR(50),
    debit_col       VARCHAR(50),
    credit_col      VARCHAR(50),
    description_col VARCHAR(50) NOT NULL,
    balance_col     VARCHAR(50),
    skip_rows       SMALLINT NOT NULL DEFAULT 0,
    notes           TEXT,
    CONSTRAINT chk_amount_cols CHECK (
        amount_col IS NOT NULL
        OR (debit_col IS NOT NULL AND credit_col IS NOT NULL)
    )
);

COMMENT ON TABLE ref.statement_providers IS
    'CSV column mapping config per financial provider. '
    'IMPORTANT: verify column names against a real sample CSV before first use. '
    'Either amount_col OR (debit_col + credit_col) must be set.';

-- ---------------------------------------------------------------------------
-- ref.accounts
-- Registry of all bank accounts and investment accounts.
-- FK to ref.statement_providers added after that table exists.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.accounts (
    account_id          SERIAL PRIMARY KEY,
    account_nme         VARCHAR(200) NOT NULL,
    provider            VARCHAR(100) NOT NULL,
    account_type        VARCHAR(50) NOT NULL
                        CHECK (account_type IN (
                            'TRANSACTION','SAVINGS','CREDIT_CARD',
                            'MORTGAGE','INVESTMENT','SUPER','OTHER')),
    bsb                 VARCHAR(10),
    account_number      VARCHAR(20),
    currency            CHAR(3) NOT NULL DEFAULT 'AUD',
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    csv_provider_id     INTEGER REFERENCES ref.statement_providers(provider_id),
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_accounts_provider
    ON ref.accounts(provider);

COMMENT ON TABLE ref.accounts IS
    'Registry of all financial accounts. '
    'csv_provider_id links to the CSV format config for statement ingestion. '
    'bsb and account_number are optional — for reference only, never sent to cloud.';

\echo '✓ 002_ref_schema.sql complete'
