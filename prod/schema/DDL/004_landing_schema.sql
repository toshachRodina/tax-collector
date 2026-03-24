-- =============================================================================
-- 004_landing_schema.sql — Landing (raw staging) schema
-- Run as taxcollectorusr against taxcollectordb
-- Idempotent: safe to re-run
-- Landing tables are APPEND-ONLY. Never UPDATE or DELETE rows here.
-- =============================================================================

\c taxcollectordb
SET search_path TO landing, public;

-- ---------------------------------------------------------------------------
-- landing.tax_documents
-- Raw extracted metadata from Gmail and folder scans.
-- No file content stored — metadata only.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS landing.tax_documents (
    landing_id          SERIAL PRIMARY KEY,
    batch_id            INTEGER NOT NULL REFERENCES ctl.process_log(batch_id),
    source_type         VARCHAR(20) NOT NULL
                        CHECK (source_type IN ('GMAIL','FOLDER','MANUAL')),
    source_id           VARCHAR(500),       -- Gmail message ID or absolute file path
    subject             VARCHAR(1000),
    sender_email        VARCHAR(500),
    received_at         TIMESTAMPTZ,
    file_name           VARCHAR(500),
    file_ext            VARCHAR(20),
    file_size_bytes     INTEGER,
    content_preview     VARCHAR(500),       -- first 500 chars of extracted text (PDF/txt only)
    raw_json            JSONB,              -- full metadata from source API
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_processed        BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_landing_tax_docs_batch
    ON landing.tax_documents(batch_id);
CREATE INDEX IF NOT EXISTS idx_landing_tax_docs_source
    ON landing.tax_documents(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_landing_tax_docs_unprocessed
    ON landing.tax_documents(is_processed) WHERE is_processed = FALSE;

-- Dedup constraint: prevents re-landing the same attachment from the same source
CREATE UNIQUE INDEX IF NOT EXISTS uidx_landing_tax_docs_dedup
    ON landing.tax_documents(source_type, source_id, COALESCE(file_name, ''));

COMMENT ON TABLE landing.tax_documents IS
    'Raw staging for tax document metadata from Gmail and folder scans. '
    'Append-only. No file content stored — metadata only. '
    'sp_merge_tax_documents merges this into core.tax_documents.';

-- ---------------------------------------------------------------------------
-- landing.financial_transactions
-- Raw CSV rows from manually-dropped bank statement files.
-- All amounts stored as raw strings — normalised in sp_merge.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS landing.financial_transactions (
    landing_id          SERIAL PRIMARY KEY,
    batch_id            INTEGER NOT NULL REFERENCES ctl.process_log(batch_id),
    source_file         VARCHAR(500) NOT NULL,
    provider            VARCHAR(100) NOT NULL,  -- 'NAB', 'Bendigo', etc.
    account_id          INTEGER REFERENCES ref.accounts(account_id),
    row_num             INTEGER NOT NULL,
    txn_date_raw        VARCHAR(50),
    amount_raw          VARCHAR(50),            -- used when single amount col
    debit_raw           VARCHAR(50),            -- used when split debit/credit cols
    credit_raw          VARCHAR(50),
    balance_raw         VARCHAR(50),
    description_raw     VARCHAR(1000),
    raw_json            JSONB,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_processed        BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_landing_fin_txn_batch
    ON landing.financial_transactions(batch_id);
CREATE INDEX IF NOT EXISTS idx_landing_fin_txn_source
    ON landing.financial_transactions(source_file, row_num);
CREATE INDEX IF NOT EXISTS idx_landing_fin_txn_unprocessed
    ON landing.financial_transactions(is_processed) WHERE is_processed = FALSE;

COMMENT ON TABLE landing.financial_transactions IS
    'Raw CSV rows from bank statement drops. All amounts as raw strings. '
    'Normalised to core.financial_transactions via sp_merge_financial_transactions.';

-- ---------------------------------------------------------------------------
-- landing.share_transactions
-- Raw CSV rows from share/broker statement drops.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS landing.share_transactions (
    landing_id          SERIAL PRIMARY KEY,
    batch_id            INTEGER NOT NULL REFERENCES ctl.process_log(batch_id),
    source_file         VARCHAR(500) NOT NULL,
    account_id          INTEGER REFERENCES ref.accounts(account_id),
    row_num             INTEGER NOT NULL,
    trade_date_raw      VARCHAR(50),
    security_raw        VARCHAR(200),
    quantity_raw        VARCHAR(50),
    price_raw           VARCHAR(50),
    value_raw           VARCHAR(50),
    trade_type_raw      VARCHAR(50),
    brokerage_raw       VARCHAR(50),
    raw_json            JSONB,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_processed        BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_landing_share_txn_batch
    ON landing.share_transactions(batch_id);
CREATE INDEX IF NOT EXISTS idx_landing_share_txn_source
    ON landing.share_transactions(source_file, row_num);
CREATE INDEX IF NOT EXISTS idx_landing_share_txn_unprocessed
    ON landing.share_transactions(is_processed) WHERE is_processed = FALSE;

COMMENT ON TABLE landing.share_transactions IS
    'Raw CSV rows from share/broker statement drops. '
    'Normalised to core.share_transactions via sp_merge_share_transactions.';

\echo '✓ 004_landing_schema.sql complete'
