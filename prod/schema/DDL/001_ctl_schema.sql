-- =============================================================================
-- 001_ctl_schema.sql — Control & Audit schema
-- Run as taxcollectorusr against taxcollectordb
-- Idempotent: safe to re-run
-- =============================================================================

\c taxcollectordb
SET search_path TO ctl, public;

-- ---------------------------------------------------------------------------
-- ctl.process_log
-- Master audit log. Every pipeline run inserts a row here.
-- All INSERT statements in application code must use RETURNING batch_id.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ctl.process_log (
    batch_id        SERIAL PRIMARY KEY,
    workflow_nme    VARCHAR(100) NOT NULL,
    script_nme      VARCHAR(200),
    status          VARCHAR(20) NOT NULL
                    CHECK (status IN ('STARTED','SUCCESS','FAILED','PARTIAL')),
    rows_extracted  INTEGER NOT NULL DEFAULT 0,
    rows_loaded     INTEGER NOT NULL DEFAULT 0,
    rows_skipped    INTEGER NOT NULL DEFAULT 0,
    error_msg       TEXT,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    meta_json       JSONB
);

CREATE INDEX IF NOT EXISTS idx_process_log_workflow
    ON ctl.process_log(workflow_nme, started_at DESC);

COMMENT ON TABLE ctl.process_log IS
    'Master audit log for all pipeline executions. '
    'All INSERT statements must use RETURNING batch_id.';

-- ---------------------------------------------------------------------------
-- ctl.ctrl_vars
-- Encrypted configuration variables (Gmail OAuth tokens, API keys, etc.)
-- Use pgp_sym_encrypt/pgp_sym_decrypt with TC_DB_PASSWORD as passphrase.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ctl.ctrl_vars (
    var_id          SERIAL PRIMARY KEY,
    package_nme     VARCHAR(100) NOT NULL,
    var_nme         VARCHAR(100) NOT NULL,
    var_val         BYTEA NOT NULL,
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (package_nme, var_nme)
);

COMMENT ON TABLE ctl.ctrl_vars IS
    'Encrypted config variables. '
    'Use pgp_sym_encrypt(value, current_setting(''app.encryption_key'')) to write, '
    'pgp_sym_decrypt to read.';

-- Helper function to retrieve all vars for a package (returns decrypted values)
CREATE OR REPLACE FUNCTION ctl.get_package_vars(p_package_nme VARCHAR)
RETURNS TABLE (var_nme VARCHAR, var_val TEXT)
LANGUAGE SQL SECURITY DEFINER AS $$
    SELECT var_nme,
           pgp_sym_decrypt(var_val, current_setting('app.encryption_key')) AS var_val
    FROM ctl.ctrl_vars
    WHERE package_nme = p_package_nme;
$$;

-- ---------------------------------------------------------------------------
-- ctl.statement_watermark
-- Tracks the last successfully loaded statement date per account.
-- Used by TC_REMIND_MISSING_STATEMENTS to detect gaps.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ctl.statement_watermark (
    watermark_id    SERIAL PRIMARY KEY,
    account_id      INTEGER NOT NULL,
    last_txn_date   DATE NOT NULL,
    last_file_nme   VARCHAR(500),
    last_loaded_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    batch_id        INTEGER REFERENCES ctl.process_log(batch_id),
    UNIQUE (account_id)
);

CREATE INDEX IF NOT EXISTS idx_statement_watermark_account
    ON ctl.statement_watermark(account_id);

COMMENT ON TABLE ctl.statement_watermark IS
    'Last successfully loaded statement date per account. '
    'UPSERT on account_id after each successful statement load.';

-- ---------------------------------------------------------------------------
-- ctl.budget_targets
-- User-defined monthly spending targets per category.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ctl.budget_targets (
    target_id       SERIAL PRIMARY KEY,
    category_id     INTEGER NOT NULL,
    fy_year         SMALLINT NOT NULL,
    month_num       SMALLINT NOT NULL CHECK (month_num BETWEEN 1 AND 12),
    budget_amount   NUMERIC(10,2) NOT NULL CHECK (budget_amount >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (category_id, fy_year, month_num)
);

COMMENT ON TABLE ctl.budget_targets IS
    'User-set monthly budget targets by spending category. '
    'NULL = no target set for that month.';

\echo '✓ 001_ctl_schema.sql complete'
