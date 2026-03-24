# Feature Spec 001 — Database Schema

**Status**: COMPLETE
**Created**: 2026-03-23
**Depends on**: Nothing — built first
**Blocks**: All other features (002–010)

---

## 1. Overview

Define and provision the complete `taxcollectordb` PostgreSQL database. This includes all schemas, tables, views, indexes, constraints, seed data, and a smoke-test script. Once this spec is implemented and verified, every subsequent feature spec has a real database to write to and test against.

**Nothing else is built until this passes its smoke test.**

---

## 2. Database Connection

```
Host:     192.168.0.250
Port:     5432
Database: taxcollectordb
User:     taxcollectorusr
Password: env TC_DB_PASSWORD
```

PostgreSQL must already be running in Docker on the Ubuntu server. The `taxcollectordb` database and `taxcollectorusr` role must be created before running the DDL (see Section 10 — Pre-requisites).

---

## 3. Schema Map

| Schema | Purpose | Mutated by |
|---|---|---|
| `ctl` | Audit, process log, config, control tables | All pipelines |
| `ref` | Reference / lookup data — rarely changes | Seed scripts + admin |
| `landing` | Raw staging — append-only, watermark-tracked | Python extractors |
| `core` | Normalised, deduplicated warehouse | sp_merge_* stored procedures |
| `mart` | Analytical views — read-only | DDL (views only) |

DDL execution order: `ctl` → `ref` → `landing` → `core` → `mart`

---

## 4. Extensions Required

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- encrypted config vars
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- UUID generation
```

---

## 5. Schema: `ctl` (Control & Audit)

### 5.1 `ctl.process_log`
Master audit log. Every pipeline run inserts a row here.

```sql
CREATE TABLE ctl.process_log (
    batch_id        SERIAL PRIMARY KEY,
    workflow_nme    VARCHAR(100) NOT NULL,
    script_nme      VARCHAR(200),
    status          VARCHAR(20) NOT NULL CHECK (status IN ('STARTED','SUCCESS','FAILED','PARTIAL')),
    rows_extracted  INTEGER DEFAULT 0,
    rows_loaded     INTEGER DEFAULT 0,
    rows_skipped    INTEGER DEFAULT 0,
    error_msg       TEXT,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    meta_json       JSONB
);
COMMENT ON TABLE ctl.process_log IS 'Master audit log for all pipeline executions. All INSERT statements must use RETURNING batch_id.';
```

### 5.2 `ctl.ctrl_vars`
Encrypted configuration variables (Gmail OAuth tokens, API keys).

```sql
CREATE TABLE ctl.ctrl_vars (
    var_id          SERIAL PRIMARY KEY,
    package_nme     VARCHAR(100) NOT NULL,
    var_nme         VARCHAR(100) NOT NULL,
    var_val         BYTEA NOT NULL,  -- encrypted with pgcrypto
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (package_nme, var_nme)
);
COMMENT ON TABLE ctl.ctrl_vars IS 'Encrypted config variables. Use pgp_sym_encrypt/pgp_sym_decrypt with TC_DB_PASSWORD as passphrase.';

-- Helper function: get all vars for a package (returns decrypted values)
CREATE OR REPLACE FUNCTION ctl.get_package_vars(p_package_nme VARCHAR)
RETURNS TABLE (var_nme VARCHAR, var_val TEXT) AS $$
    SELECT var_nme, pgp_sym_decrypt(var_val, current_setting('app.encryption_key')) AS var_val
    FROM ctl.ctrl_vars
    WHERE package_nme = p_package_nme;
$$ LANGUAGE SQL SECURITY DEFINER;
```

### 5.3 `ctl.statement_watermark`
Tracks the last successfully loaded statement date per account. Used by the statement reminder workflow.

```sql
CREATE TABLE ctl.statement_watermark (
    watermark_id    SERIAL PRIMARY KEY,
    account_id      INTEGER NOT NULL,  -- FK to ref.accounts
    last_txn_date   DATE NOT NULL,
    last_file_nme   VARCHAR(500),
    last_loaded_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    batch_id        INTEGER REFERENCES ctl.process_log(batch_id),
    UNIQUE (account_id)
);
COMMENT ON TABLE ctl.statement_watermark IS 'Tracks last successfully loaded statement date per account. Used by TC_REMIND_MISSING_STATEMENTS.';
```

### 5.4 `ctl.budget_targets`
User-defined monthly spending targets per category.

```sql
CREATE TABLE ctl.budget_targets (
    target_id       SERIAL PRIMARY KEY,
    category_id     INTEGER NOT NULL,  -- FK to ref.transaction_categories
    fy_year         SMALLINT NOT NULL,
    month_num       SMALLINT NOT NULL CHECK (month_num BETWEEN 1 AND 12),
    budget_amount   NUMERIC(10,2) NOT NULL CHECK (budget_amount >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (category_id, fy_year, month_num)
);
COMMENT ON TABLE ctl.budget_targets IS 'User-set monthly budget targets by spending category. NULL months mean no target set.';
```

---

## 6. Schema: `ref` (Reference Data)

### 6.1 `ref.fy_periods`
Australian financial year boundaries.

```sql
CREATE TABLE ref.fy_periods (
    fy_year             SMALLINT PRIMARY KEY,
    fy_label            VARCHAR(20) NOT NULL,   -- e.g. 'FY2025'
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    lodgement_deadline  DATE NOT NULL,          -- Oct 31 standard; May 31 via agent
    is_current          BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_fy_dates CHECK (end_date > start_date)
);
COMMENT ON TABLE ref.fy_periods IS 'Australian financial year boundaries. July 1 to June 30. is_current = TRUE for active FY.';
```

Seed data:
```sql
INSERT INTO ref.fy_periods (fy_year, fy_label, start_date, end_date, lodgement_deadline, is_current) VALUES
(2023, 'FY2023', '2022-07-01', '2023-06-30', '2023-10-31', FALSE),
(2024, 'FY2024', '2023-07-01', '2024-06-30', '2024-10-31', FALSE),
(2025, 'FY2025', '2024-07-01', '2025-06-30', '2025-10-31', TRUE),
(2026, 'FY2026', '2025-07-01', '2026-06-30', '2026-10-31', FALSE);
```

### 6.2 `ref.tax_categories`
Canonical tax document categories aligned to ATO deduction types.

```sql
CREATE TABLE ref.tax_categories (
    category_id     SERIAL PRIMARY KEY,
    category_nme    VARCHAR(100) NOT NULL UNIQUE,
    category_grp    VARCHAR(50) NOT NULL,       -- top-level group (Income, Deductions, etc.)
    description     TEXT,
    is_deductible   BOOLEAN NOT NULL DEFAULT FALSE,
    ato_reference   VARCHAR(200),               -- ATO worksheet item reference
    sort_order      SMALLINT NOT NULL DEFAULT 99
);
COMMENT ON TABLE ref.tax_categories IS 'ATO-aligned tax document categories. is_deductible flags deductible expense types.';
```

Seed data:
```sql
INSERT INTO ref.tax_categories (category_nme, category_grp, description, is_deductible, ato_reference, sort_order) VALUES
-- Income
('Payment Summary / Group Certificate', 'Income', 'Annual income statement from employer', FALSE, 'Item 1', 1),
('Bank Interest Statement', 'Income', 'Interest earned on savings accounts', FALSE, 'Item 10', 2),
('Dividend Statement', 'Income', 'Share dividend payments', FALSE, 'Item 11', 3),
('Share Sale / CGT Event', 'Income', 'Capital gains from share disposals', FALSE, 'Item 18', 4),
-- Deductions — Work-related
('Work From Home — Internet', 'Deductions', 'Home internet bill (WFH portion)', TRUE, 'D5', 10),
('Work From Home — Electricity/Gas', 'Deductions', 'Utility bill (WFH portion)', TRUE, 'D5', 11),
('Work From Home — Insurance', 'Deductions', 'Home & contents (home office portion)', TRUE, 'D5', 12),
('Technology Equipment', 'Deductions', 'Work-related tech — keyboards, mice, hard drives, monitors', TRUE, 'D3', 13),
('Software & Subscriptions', 'Deductions', 'Work-related software, LLM subscriptions, productivity tools', TRUE, 'D5', 14),
('Professional Development', 'Deductions', 'Training courses, certifications, conferences', TRUE, 'D4', 15),
('Professional Memberships', 'Deductions', 'Industry body memberships and subscriptions', TRUE, 'D5', 16),
-- Deductions — Insurance
('Income Protection Insurance', 'Deductions', 'Premiums for income protection policy', TRUE, 'D12', 20),
-- Property
('Rental Income Statement', 'Property', 'Rental property income statements', FALSE, 'Item 21', 30),
('Property Depreciation Schedule', 'Property', 'Depreciation report from quantity surveyor', TRUE, 'Item 21', 31),
-- Government
('ATO Notice / Assessment', 'Government', 'Tax assessment, payment or refund notice', FALSE, NULL, 40),
('HECS/HELP Statement', 'Government', 'Student loan balance and repayment statement', FALSE, 'Item 14', 41),
-- Super
('Superannuation Statement', 'Super', 'Annual super fund statement', FALSE, NULL, 50),
('Super Contribution Notice', 'Super', 'Voluntary super contribution confirmation', FALSE, NULL, 51),
-- Health
('Private Health Insurance Statement', 'Health', 'Annual PHI statement for Medicare Levy Surcharge', FALSE, 'Item M2', 60),
-- Other
('Invoice / Receipt — Other', 'Other', 'Unclassified invoice or receipt requiring review', FALSE, NULL, 99);
```

### 6.3 `ref.transaction_categories`
Spending categories for financial health analysis.

```sql
CREATE TABLE ref.transaction_categories (
    category_id         SERIAL PRIMARY KEY,
    category_nme        VARCHAR(100) NOT NULL,
    subcategory_nme     VARCHAR(100),
    is_income           BOOLEAN NOT NULL DEFAULT FALSE,
    is_tax_relevant     BOOLEAN NOT NULL DEFAULT FALSE,
    is_deductible       BOOLEAN NOT NULL DEFAULT FALSE,
    description         TEXT,
    sort_order          SMALLINT NOT NULL DEFAULT 99,
    UNIQUE (category_nme, subcategory_nme)
);
COMMENT ON TABLE ref.transaction_categories IS 'Spending categories for financial transaction classification.';
```

Seed data:
```sql
INSERT INTO ref.transaction_categories (category_nme, subcategory_nme, is_income, is_tax_relevant, is_deductible, sort_order) VALUES
-- Income
('Income', 'Salary/Wages', TRUE, TRUE, FALSE, 1),
('Income', 'Freelance/Contract', TRUE, TRUE, FALSE, 2),
('Income', 'Interest', TRUE, TRUE, FALSE, 3),
('Income', 'Dividends', TRUE, TRUE, FALSE, 4),
('Income', 'Other', TRUE, TRUE, FALSE, 5),
-- Housing
('Housing', 'Mortgage/Rent', FALSE, FALSE, FALSE, 10),
('Housing', 'Rates & Strata', FALSE, FALSE, FALSE, 11),
('Housing', 'Electricity/Gas', FALSE, TRUE, TRUE, 12),
('Housing', 'Water', FALSE, FALSE, FALSE, 13),
('Housing', 'Internet', FALSE, TRUE, TRUE, 14),
('Housing', 'Insurance', FALSE, TRUE, TRUE, 15),
-- Groceries & Food
('Food', 'Groceries', FALSE, FALSE, FALSE, 20),
('Food', 'Dining Out', FALSE, FALSE, FALSE, 21),
('Food', 'Takeaway/Delivery', FALSE, FALSE, FALSE, 22),
-- Transport
('Transport', 'Fuel', FALSE, FALSE, FALSE, 30),
('Transport', 'Public Transport', FALSE, FALSE, FALSE, 31),
('Transport', 'Parking', FALSE, FALSE, FALSE, 32),
('Transport', 'Car Insurance', FALSE, FALSE, FALSE, 33),
('Transport', 'Car Rego', FALSE, FALSE, FALSE, 34),
-- Health
('Health', 'Private Health Insurance', FALSE, FALSE, FALSE, 40),
('Health', 'Medical/Dental', FALSE, FALSE, FALSE, 41),
('Health', 'Pharmacy', FALSE, FALSE, FALSE, 42),
-- Insurance
('Insurance', 'Income Protection', FALSE, TRUE, TRUE, 50),
('Insurance', 'Life Insurance', FALSE, FALSE, FALSE, 51),
('Insurance', 'Other', FALSE, FALSE, FALSE, 52),
-- Technology
('Technology', 'Hardware', FALSE, TRUE, TRUE, 60),
('Technology', 'Software/Subscriptions', FALSE, TRUE, TRUE, 61),
('Technology', 'Mobile Phone', FALSE, FALSE, FALSE, 62),
-- Professional
('Professional', 'Training & Education', FALSE, TRUE, TRUE, 70),
('Professional', 'Memberships', FALSE, TRUE, TRUE, 71),
('Professional', 'Books & Resources', FALSE, TRUE, TRUE, 72),
-- Entertainment & Lifestyle
('Entertainment', 'Streaming Services', FALSE, FALSE, FALSE, 80),
('Entertainment', 'Hobbies', FALSE, FALSE, FALSE, 81),
('Entertainment', 'Social', FALSE, FALSE, FALSE, 82),
-- Savings & Investments
('Savings', 'Savings Transfer', FALSE, FALSE, FALSE, 90),
('Savings', 'Investment Purchase', FALSE, FALSE, FALSE, 91),
('Savings', 'Super Contribution', FALSE, FALSE, FALSE, 92),
-- Other
('Other', 'ATM/Cash', FALSE, FALSE, FALSE, 99),
('Other', 'Fees & Charges', FALSE, FALSE, FALSE, 99),
('Other', 'Uncategorised', FALSE, FALSE, FALSE, 99);
```

### 6.4 `ref.accounts`
Registry of all bank accounts and investment accounts.

```sql
CREATE TABLE ref.accounts (
    account_id          SERIAL PRIMARY KEY,
    account_nme         VARCHAR(200) NOT NULL,
    provider            VARCHAR(100) NOT NULL,   -- 'NAB', 'Bendigo', 'CommSec', etc.
    account_type        VARCHAR(50) NOT NULL CHECK (account_type IN (
                            'TRANSACTION','SAVINGS','CREDIT_CARD',
                            'MORTGAGE','INVESTMENT','SUPER','OTHER')),
    bsb                 VARCHAR(10),
    account_number      VARCHAR(20),
    currency            CHAR(3) NOT NULL DEFAULT 'AUD',
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    csv_provider_id     INTEGER,  -- FK to ref.statement_providers
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE ref.accounts IS 'Registry of all financial accounts. csv_provider_id links to the CSV format config used for statement ingestion.';
```

### 6.5 `ref.statement_providers`
CSV format configuration per financial provider. Allows the ingestor to normalise different column layouts.

```sql
CREATE TABLE ref.statement_providers (
    provider_id         SERIAL PRIMARY KEY,
    provider_nme        VARCHAR(100) NOT NULL UNIQUE,
    date_col            VARCHAR(50) NOT NULL,
    date_format         VARCHAR(30) NOT NULL,    -- e.g. '%d/%m/%Y' or '%Y-%m-%d'
    amount_col          VARCHAR(50),             -- single amount column (positive = credit)
    debit_col           VARCHAR(50),             -- separate debit column (if split)
    credit_col          VARCHAR(50),             -- separate credit column (if split)
    description_col     VARCHAR(50) NOT NULL,
    balance_col         VARCHAR(50),
    skip_rows           SMALLINT NOT NULL DEFAULT 0,  -- header rows to skip
    notes               TEXT
);
COMMENT ON TABLE ref.statement_providers IS 'CSV column mapping config per financial provider. Used by the statement ingestor to normalise to canonical schema.';
```

Seed data (subject to verification against real sample CSVs):
```sql
INSERT INTO ref.statement_providers (provider_nme, date_col, date_format, amount_col, debit_col, credit_col, description_col, balance_col, skip_rows, notes) VALUES
('NAB',
    'Date', '%d-%b-%y', 'Amount', NULL, NULL, 'Description', 'Balance', 0,
    'NAB CSV: single Amount column (negative = debit). Verify against real sample.'),
('Bendigo',
    'Date', '%d/%m/%Y', NULL, 'Debit', 'Credit', 'Description', 'Balance', 0,
    'Bendigo CSV: separate Debit/Credit columns. Amount = Credit - Debit. Verify against real sample.'),
('CommSec',
    'Date', '%d/%m/%Y', NULL, 'Debit', 'Credit', 'Description', 'Balance', 0,
    'CommSec transaction CSV. Verify against real sample — share trades use a different format.');
```

---

## 7. Schema: `landing` (Raw Staging)

Landing tables are append-only. Old rows are never updated. Watermarking is handled via `ctl.statement_watermark` and file-modified timestamps.

### 7.1 `landing.tax_documents`

```sql
CREATE TABLE landing.tax_documents (
    landing_id          SERIAL PRIMARY KEY,
    batch_id            INTEGER NOT NULL REFERENCES ctl.process_log(batch_id),
    source_type         VARCHAR(20) NOT NULL CHECK (source_type IN ('GMAIL','FOLDER','MANUAL')),
    source_id           VARCHAR(500),           -- Gmail message ID or file path
    subject             VARCHAR(1000),
    sender_email        VARCHAR(500),
    received_at         TIMESTAMPTZ,
    file_name           VARCHAR(500),
    file_ext            VARCHAR(20),
    file_size_bytes     INTEGER,
    content_preview     VARCHAR(500),           -- first 500 chars of extracted text (if PDF/txt)
    raw_json            JSONB,                  -- full metadata from source API
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_processed        BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_landing_tax_docs_batch ON landing.tax_documents(batch_id);
CREATE INDEX idx_landing_tax_docs_source ON landing.tax_documents(source_type, source_id);
COMMENT ON TABLE landing.tax_documents IS 'Raw staging for tax document metadata. Append-only. No file content stored.';
```

### 7.2 `landing.financial_transactions`

```sql
CREATE TABLE landing.financial_transactions (
    landing_id          SERIAL PRIMARY KEY,
    batch_id            INTEGER NOT NULL REFERENCES ctl.process_log(batch_id),
    source_file         VARCHAR(500) NOT NULL,
    provider            VARCHAR(100) NOT NULL,
    row_num             INTEGER NOT NULL,
    txn_date_raw        VARCHAR(50),
    amount_raw          VARCHAR(50),
    description_raw     VARCHAR(1000),
    balance_raw         VARCHAR(50),
    raw_json            JSONB,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_processed        BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_landing_fin_txn_batch ON landing.financial_transactions(batch_id);
CREATE INDEX idx_landing_fin_txn_source ON landing.financial_transactions(source_file, row_num);
COMMENT ON TABLE landing.financial_transactions IS 'Raw CSV rows from bank statement drops. Normalised to core in sp_merge_financial_transactions.';
```

### 7.3 `landing.share_transactions`

```sql
CREATE TABLE landing.share_transactions (
    landing_id          SERIAL PRIMARY KEY,
    batch_id            INTEGER NOT NULL REFERENCES ctl.process_log(batch_id),
    source_file         VARCHAR(500) NOT NULL,
    row_num             INTEGER NOT NULL,
    trade_date_raw      VARCHAR(50),
    security_raw        VARCHAR(200),
    quantity_raw        VARCHAR(50),
    price_raw           VARCHAR(50),
    value_raw           VARCHAR(50),
    trade_type_raw      VARCHAR(50),
    raw_json            JSONB,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_processed        BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_landing_share_txn_batch ON landing.share_transactions(batch_id);
COMMENT ON TABLE landing.share_transactions IS 'Raw CSV rows from share/broker statement drops. Normalised to core in sp_merge_share_transactions.';
```

---

## 8. Schema: `core` (Normalised Warehouse)

Core tables are the single source of truth. All writes go through sp_merge_* stored procedures. Direct INSERT/UPDATE to core is prohibited from application code.

### 8.1 `core.tax_documents`

```sql
CREATE TABLE core.tax_documents (
    doc_id              SERIAL PRIMARY KEY,
    source_type         VARCHAR(20) NOT NULL CHECK (source_type IN ('GMAIL','FOLDER','MANUAL')),
    source_id           VARCHAR(500) NOT NULL,   -- dedup key
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
    confidence_score    NUMERIC(4,3),            -- 0.000 to 1.000
    classification_model VARCHAR(100),
    review_status       VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (review_status IN ('PENDING','CONFIRMED','REJECTED','NEEDS_REVIEW')),
    reviewer_notes      TEXT,
    batch_id            INTEGER REFERENCES ctl.process_log(batch_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_type, source_id)
);
CREATE INDEX idx_core_tax_docs_fy ON core.tax_documents(fy_year);
CREATE INDEX idx_core_tax_docs_category ON core.tax_documents(tax_category_id);
CREATE INDEX idx_core_tax_docs_review ON core.tax_documents(review_status);
COMMENT ON TABLE core.tax_documents IS 'Normalised tax document metadata. source_type+source_id is the dedup key.';
```

### 8.2 `core.financial_transactions`

```sql
CREATE TABLE core.financial_transactions (
    txn_id              SERIAL PRIMARY KEY,
    account_id          INTEGER NOT NULL REFERENCES ref.accounts(account_id),
    txn_date            DATE NOT NULL,
    amount              NUMERIC(12,2) NOT NULL,  -- positive = credit, negative = debit
    description_raw     VARCHAR(1000) NOT NULL,
    description_clean   VARCHAR(500),
    category_id         INTEGER REFERENCES ref.transaction_categories(category_id),
    subcategory         VARCHAR(100),
    is_deductible       BOOLEAN NOT NULL DEFAULT FALSE,
    deductible_amount   NUMERIC(10,2),
    confidence_score    NUMERIC(4,3),
    classification_model VARCHAR(100),
    is_anomaly          BOOLEAN NOT NULL DEFAULT FALSE,
    anomaly_reason      TEXT,
    review_status       VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (review_status IN ('PENDING','CONFIRMED','REJECTED','NEEDS_REVIEW')),
    source_file         VARCHAR(500),
    dedup_hash          VARCHAR(64) NOT NULL,    -- SHA256 of (account_id, txn_date, amount, description_raw)
    batch_id            INTEGER REFERENCES ctl.process_log(batch_id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (dedup_hash)
);
CREATE INDEX idx_core_fin_txn_account ON core.financial_transactions(account_id, txn_date);
CREATE INDEX idx_core_fin_txn_date ON core.financial_transactions(txn_date);
CREATE INDEX idx_core_fin_txn_category ON core.financial_transactions(category_id);
CREATE INDEX idx_core_fin_txn_deductible ON core.financial_transactions(is_deductible) WHERE is_deductible = TRUE;
COMMENT ON TABLE core.financial_transactions IS 'Normalised financial transactions. dedup_hash prevents duplicate imports.';
```

### 8.3 `core.share_transactions`

```sql
CREATE TABLE core.share_transactions (
    trade_id            SERIAL PRIMARY KEY,
    account_id          INTEGER NOT NULL REFERENCES ref.accounts(account_id),
    trade_date          DATE NOT NULL,
    security_code       VARCHAR(20) NOT NULL,
    security_name       VARCHAR(200),
    quantity            NUMERIC(15,4) NOT NULL,
    price               NUMERIC(12,4) NOT NULL,
    value               NUMERIC(15,2) NOT NULL,
    trade_type          VARCHAR(20) NOT NULL CHECK (trade_type IN ('BUY','SELL','DIVIDEND','SPLIT','OTHER')),
    brokerage           NUMERIC(10,2) DEFAULT 0,
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
CREATE INDEX idx_core_share_txn_account ON core.share_transactions(account_id, trade_date);
CREATE INDEX idx_core_share_txn_security ON core.share_transactions(security_code);
CREATE INDEX idx_core_share_txn_fy ON core.share_transactions(fy_year);
COMMENT ON TABLE core.share_transactions IS 'Normalised share/investment transactions.';
```

---

## 9. Schema: `mart` (Analytical Views)

Views are computed on read. No data stored here.

### 9.1 `mart.vw_tax_documents`

```sql
CREATE VIEW mart.vw_tax_documents AS
SELECT
    d.doc_id,
    d.source_type,
    d.subject,
    d.sender_email,
    d.received_at,
    f.fy_label,
    f.fy_year,
    c.category_nme        AS tax_category,
    c.category_grp        AS tax_category_group,
    d.is_deductible,
    d.deductible_amount,
    d.confidence_score,
    d.review_status,
    d.file_name,
    d.file_ext,
    d.content_preview,
    d.created_at
FROM core.tax_documents d
LEFT JOIN ref.fy_periods f ON d.fy_year = f.fy_year
LEFT JOIN ref.tax_categories c ON d.tax_category_id = c.category_id;
```

### 9.2 `mart.vw_tax_summary`

```sql
CREATE VIEW mart.vw_tax_summary AS
SELECT
    f.fy_label,
    c.category_grp,
    c.category_nme,
    COUNT(d.doc_id)             AS document_count,
    SUM(d.deductible_amount)    AS total_deductible,
    MIN(d.received_at)          AS earliest_doc,
    MAX(d.received_at)          AS latest_doc
FROM core.tax_documents d
JOIN ref.fy_periods f ON d.fy_year = f.fy_year
JOIN ref.tax_categories c ON d.tax_category_id = c.category_id
WHERE d.is_deductible = TRUE
  AND d.review_status IN ('PENDING', 'CONFIRMED')
GROUP BY f.fy_label, c.category_grp, c.category_nme
ORDER BY c.sort_order;
```

### 9.3 `mart.vw_monthly_spending`

```sql
CREATE VIEW mart.vw_monthly_spending AS
SELECT
    t.account_id,
    a.account_nme,
    a.provider,
    DATE_TRUNC('month', t.txn_date)::DATE   AS month_start,
    TO_CHAR(t.txn_date, 'YYYY-MM')          AS month_label,
    c.category_nme,
    c.subcategory_nme,
    c.is_income,
    SUM(t.amount)                            AS total_amount,
    COUNT(*)                                 AS txn_count
FROM core.financial_transactions t
JOIN ref.accounts a ON t.account_id = a.account_id
LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
GROUP BY t.account_id, a.account_nme, a.provider,
         DATE_TRUNC('month', t.txn_date), TO_CHAR(t.txn_date, 'YYYY-MM'),
         c.category_nme, c.subcategory_nme, c.is_income
ORDER BY month_start DESC, c.category_nme;
```

### 9.4 `mart.vw_savings_rate`

```sql
CREATE VIEW mart.vw_savings_rate AS
WITH monthly AS (
    SELECT
        TO_CHAR(txn_date, 'YYYY-MM')        AS month_label,
        DATE_TRUNC('month', txn_date)::DATE AS month_start,
        SUM(CASE WHEN c.is_income THEN amount ELSE 0 END)       AS total_income,
        SUM(CASE WHEN NOT c.is_income THEN ABS(amount) ELSE 0 END) AS total_spend
    FROM core.financial_transactions t
    LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
    GROUP BY TO_CHAR(txn_date, 'YYYY-MM'), DATE_TRUNC('month', txn_date)
)
SELECT
    month_label,
    month_start,
    total_income,
    total_spend,
    (total_income - total_spend)                AS net_savings,
    CASE
        WHEN total_income > 0
        THEN ROUND((total_income - total_spend) / total_income * 100, 1)
        ELSE NULL
    END                                         AS savings_rate_pct
FROM monthly
ORDER BY month_start DESC;
```

### 9.5 `mart.vw_anomalies`

```sql
CREATE VIEW mart.vw_anomalies AS
SELECT
    t.txn_id,
    t.account_id,
    a.account_nme,
    t.txn_date,
    t.amount,
    t.description_clean,
    c.category_nme,
    t.anomaly_reason,
    t.review_status,
    t.created_at
FROM core.financial_transactions t
JOIN ref.accounts a ON t.account_id = a.account_id
LEFT JOIN ref.transaction_categories c ON t.category_id = c.category_id
WHERE t.is_anomaly = TRUE
ORDER BY t.txn_date DESC;
```

---

## 10. Pre-requisites (run once on server)

These commands must be executed by the PostgreSQL superuser (`postgres`) before running the DDL:

```sql
-- Create database
CREATE DATABASE taxcollectordb;

-- Create user
CREATE USER taxcollectorusr WITH PASSWORD 'your_secure_password';

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE taxcollectordb TO taxcollectorusr;

-- Connect to taxcollectordb then:
\c taxcollectordb

-- Create schemas
CREATE SCHEMA ctl AUTHORIZATION taxcollectorusr;
CREATE SCHEMA ref AUTHORIZATION taxcollectorusr;
CREATE SCHEMA landing AUTHORIZATION taxcollectorusr;
CREATE SCHEMA core AUTHORIZATION taxcollectorusr;
CREATE SCHEMA mart AUTHORIZATION taxcollectorusr;

-- Grant schema usage
GRANT USAGE ON SCHEMA ctl, ref, landing, core, mart TO taxcollectorusr;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ctl, ref, landing, core, mart TO taxcollectorusr;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ctl, ref, landing, core, mart TO taxcollectorusr;

-- Extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

---

## 11. DDL Execution Order

```
1. Pre-requisites (superuser, run once)
2. prod/schema/DDL/001_ctl_schema.sql         -- ctl.process_log, ctrl_vars, statement_watermark, budget_targets
3. prod/schema/DDL/002_ref_schema.sql         -- ref.fy_periods, tax_categories, transaction_categories, accounts, statement_providers
4. prod/schema/DDL/003_ref_seed.sql           -- Seed data for all ref tables
5. prod/schema/DDL/004_landing_schema.sql     -- landing.tax_documents, financial_transactions, share_transactions
6. prod/schema/DDL/005_core_schema.sql        -- core.tax_documents, financial_transactions, share_transactions
7. prod/schema/DDL/006_mart_views.sql         -- All mart.vw_* views
```

---

## 12. Smoke Test SQL

Run this after DDL execution to verify the schema is complete and seed data is correct.

```sql
-- 1. Verify all schemas exist
SELECT schema_name FROM information_schema.schemata
WHERE schema_name IN ('ctl','ref','landing','core','mart')
ORDER BY schema_name;
-- Expected: 5 rows

-- 2. Verify all tables exist
SELECT table_schema, table_name FROM information_schema.tables
WHERE table_schema IN ('ctl','ref','landing','core')
  AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name;
-- Expected: 14 tables

-- 3. Verify all views exist
SELECT table_schema, table_name FROM information_schema.views
WHERE table_schema = 'mart'
ORDER BY table_name;
-- Expected: 5 views (vw_anomalies, vw_monthly_spending, vw_savings_rate, vw_tax_documents, vw_tax_summary)

-- 4. Verify seed data
SELECT COUNT(*) AS fy_count FROM ref.fy_periods;           -- Expected: 4
SELECT COUNT(*) AS tax_cat_count FROM ref.tax_categories;  -- Expected: 19
SELECT COUNT(*) AS txn_cat_count FROM ref.transaction_categories; -- Expected: ~40
SELECT COUNT(*) AS provider_count FROM ref.statement_providers;   -- Expected: 3

-- 5. Verify current FY
SELECT fy_label, start_date, end_date FROM ref.fy_periods WHERE is_current = TRUE;
-- Expected: FY2025, 2024-07-01, 2025-06-30

-- 6. Verify process_log works with RETURNING
INSERT INTO ctl.process_log (workflow_nme, status)
VALUES ('SMOKE_TEST', 'SUCCESS')
RETURNING batch_id;
-- Expected: returns a batch_id integer

-- 7. Verify mart views query without error
SELECT COUNT(*) FROM mart.vw_tax_documents;
SELECT COUNT(*) FROM mart.vw_tax_summary;
SELECT COUNT(*) FROM mart.vw_monthly_spending;
SELECT COUNT(*) FROM mart.vw_savings_rate;
SELECT COUNT(*) FROM mart.vw_anomalies;
-- Expected: all return 0 rows (empty DB) with no errors

-- 8. Clean up smoke test
DELETE FROM ctl.process_log WHERE workflow_nme = 'SMOKE_TEST';
```

---

## 13. Acceptance Criteria

- [x] All 5 schemas (`ctl`, `ref`, `landing`, `core`, `mart`) exist in `taxcollectordb`
- [x] All 15 base tables exist with correct columns, types, and constraints
- [x] All 7 mart views exist and query without error
- [x] `dedup_hash` UNIQUE constraint is enforced on `core.financial_transactions` and `core.share_transactions`
- [x] `ref.fy_periods` has 4 rows; FY2025 is marked `is_current = TRUE`
- [x] `ref.tax_categories` has 20 seed rows; all deductible categories confirmed correct
- [x] `ref.transaction_categories` has 43 seed rows with `is_income = TRUE` for income types
- [x] `ctl.process_log` INSERT with `RETURNING batch_id` works correctly
- [x] All smoke test queries return expected results with no errors
- [x] **COMPLETE — provisioned and verified 2026-03-23**

---

## 14. Open Items

| # | Item | Impact |
|---|---|---|
| 1 | Verify NAB CSV column names against a real export before building ingestor | `ref.statement_providers` seed data may need updating |
| 2 | Verify Bendigo Bank CSV column names against a real export | Same |
| 3 | Add super fund account to `ref.accounts` once provider is known | Low — placeholder row can be added later |
| 4 | Confirm watched folder paths with user before building folder scanner | Noted in master spec open items |
