-- =============================================================================
-- 005_core_schema.sql — Core (normalised warehouse) schema
-- Run as taxcollectorusr against taxcollectordb
-- Idempotent: safe to re-run
-- All writes to core go through sp_merge_* stored procedures only.
-- Direct INSERT/UPDATE from application code is prohibited.
-- =============================================================================

\c taxcollectordb
SET search_path TO core, public;

-- ---------------------------------------------------------------------------
-- core.tax_documents
-- Normalised, deduplicated tax document metadata.
-- Dedup key: (source_type, source_id)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.tax_documents (
    doc_id              SERIAL PRIMARY KEY,
    source_type         VARCHAR(20) NOT NULL
                        CHECK (source_type IN ('GMAIL','FOLDER','MANUAL')),
    source_id           VARCHAR(500) NOT NULL,
    subject             VARCHAR(1000),
    sender_email        VARCHAR(500),
    received_at         TIMESTAMPTZ,
    fy_year             SMALLINT REFERENCES ref.fy_periods(fy_year),
    file_name           VARCHAR(500),
    file_ext            VARCHAR(20),
    file_size_bytes     INTEGER,
    content_preview     VARCHAR(500),
    tax_category_id     INTEGER REFERENCES ref.tax_categories(category_id),
    is_deductible       BOOLEAN,
    deductible_amount   NUMERIC(10,2),
    confidence_score    NUMERIC(4,3) CHECK (confidence_score BETWEEN 0 AND 1),
    classification_model VARCHAR(100),
    review_status       VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (review_status IN (
                            'PENDING','CONFIRMED','REJECTED','NEEDS_REVIEW')),
    reviewer_notes      TEXT,
    batch_id            INTEGER REFERENCES ctl.process_log(batch_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_type, source_id)
);

CREATE INDEX IF NOT EXISTS idx_core_tax_docs_fy
    ON core.tax_documents(fy_year);
CREATE INDEX IF NOT EXISTS idx_core_tax_docs_category
    ON core.tax_documents(tax_category_id);
CREATE INDEX IF NOT EXISTS idx_core_tax_docs_review
    ON core.tax_documents(review_status);
CREATE INDEX IF NOT EXISTS idx_core_tax_docs_unclassified
    ON core.tax_documents(tax_category_id) WHERE tax_category_id IS NULL;

COMMENT ON TABLE core.tax_documents IS
    'Normalised tax document metadata. (source_type, source_id) is the dedup key. '
    'Direct INSERT/UPDATE from application code is prohibited — use sp_merge_tax_documents.';

-- Trigger: auto-update updated_at on any UPDATE
CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tax_docs_updated_at ON core.tax_documents;
CREATE TRIGGER trg_tax_docs_updated_at
    BEFORE UPDATE ON core.tax_documents
    FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- ---------------------------------------------------------------------------
-- core.financial_transactions
-- Normalised, deduplicated financial transactions.
-- Dedup key: SHA256 hash of (account_id || txn_date || amount || description_raw)
-- Sign convention: positive = credit (money in), negative = debit (money out)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.financial_transactions (
    txn_id              SERIAL PRIMARY KEY,
    account_id          INTEGER NOT NULL REFERENCES ref.accounts(account_id),
    txn_date            DATE NOT NULL,
    amount              NUMERIC(12,2) NOT NULL,
    description_raw     VARCHAR(1000) NOT NULL,
    description_clean   VARCHAR(500),
    category_id         INTEGER REFERENCES ref.transaction_categories(category_id),
    subcategory         VARCHAR(100),
    is_deductible       BOOLEAN NOT NULL DEFAULT FALSE,
    deductible_amount   NUMERIC(10,2),
    confidence_score    NUMERIC(4,3) CHECK (confidence_score BETWEEN 0 AND 1),
    classification_model VARCHAR(100),
    is_anomaly          BOOLEAN NOT NULL DEFAULT FALSE,
    anomaly_reason      TEXT,
    review_status       VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (review_status IN (
                            'PENDING','CONFIRMED','REJECTED','NEEDS_REVIEW')),
    source_file         VARCHAR(500),
    dedup_hash          VARCHAR(64) NOT NULL,
    batch_id            INTEGER REFERENCES ctl.process_log(batch_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (dedup_hash)
);

CREATE INDEX IF NOT EXISTS idx_core_fin_txn_account_date
    ON core.financial_transactions(account_id, txn_date);
CREATE INDEX IF NOT EXISTS idx_core_fin_txn_date
    ON core.financial_transactions(txn_date);
CREATE INDEX IF NOT EXISTS idx_core_fin_txn_category
    ON core.financial_transactions(category_id);
CREATE INDEX IF NOT EXISTS idx_core_fin_txn_deductible
    ON core.financial_transactions(is_deductible, txn_date)
    WHERE is_deductible = TRUE;
CREATE INDEX IF NOT EXISTS idx_core_fin_txn_unclassified
    ON core.financial_transactions(category_id)
    WHERE category_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_core_fin_txn_anomalies
    ON core.financial_transactions(is_anomaly)
    WHERE is_anomaly = TRUE;

COMMENT ON TABLE core.financial_transactions IS
    'Normalised financial transactions from bank statement imports. '
    'dedup_hash = SHA256(account_id || txn_date || amount || description_raw). '
    'positive amount = credit (money in), negative = debit (money out). '
    'Direct INSERT/UPDATE from application code is prohibited — use sp_merge_financial_transactions.';

DROP TRIGGER IF EXISTS trg_fin_txn_updated_at ON core.financial_transactions;
CREATE TRIGGER trg_fin_txn_updated_at
    BEFORE UPDATE ON core.financial_transactions
    FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- ---------------------------------------------------------------------------
-- core.share_transactions
-- Normalised share / investment trade records.
-- Dedup key: SHA256 hash of (account_id || trade_date || security_code || quantity || trade_type)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.share_transactions (
    trade_id            SERIAL PRIMARY KEY,
    account_id          INTEGER NOT NULL REFERENCES ref.accounts(account_id),
    trade_date          DATE NOT NULL,
    security_code       VARCHAR(20) NOT NULL,
    security_name       VARCHAR(200),
    quantity            NUMERIC(15,4) NOT NULL,
    price               NUMERIC(12,4) NOT NULL,
    value               NUMERIC(15,2) NOT NULL,
    trade_type          VARCHAR(20) NOT NULL
                        CHECK (trade_type IN ('BUY','SELL','DIVIDEND','SPLIT','OTHER')),
    brokerage           NUMERIC(10,2) NOT NULL DEFAULT 0,
    cost_base           NUMERIC(15,2),
    cgt_event           BOOLEAN NOT NULL DEFAULT FALSE,
    fy_year             SMALLINT REFERENCES ref.fy_periods(fy_year),
    dedup_hash          VARCHAR(64) NOT NULL,
    source_file         VARCHAR(500),
    batch_id            INTEGER REFERENCES ctl.process_log(batch_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (dedup_hash)
);

CREATE INDEX IF NOT EXISTS idx_core_share_txn_account_date
    ON core.share_transactions(account_id, trade_date);
CREATE INDEX IF NOT EXISTS idx_core_share_txn_security
    ON core.share_transactions(security_code);
CREATE INDEX IF NOT EXISTS idx_core_share_txn_fy
    ON core.share_transactions(fy_year);
CREATE INDEX IF NOT EXISTS idx_core_share_txn_cgt
    ON core.share_transactions(cgt_event, trade_date)
    WHERE cgt_event = TRUE;

COMMENT ON TABLE core.share_transactions IS
    'Normalised share and investment transactions. '
    'dedup_hash = SHA256(account_id || trade_date || security_code || quantity || trade_type). '
    'Direct INSERT/UPDATE from application code is prohibited — use sp_merge_share_transactions.';

DROP TRIGGER IF EXISTS trg_share_txn_updated_at ON core.share_transactions;
CREATE TRIGGER trg_share_txn_updated_at
    BEFORE UPDATE ON core.share_transactions
    FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

\echo '✓ 005_core_schema.sql complete'
