-- =============================================================================
-- 007_tax_checklist.sql
-- Tax Checklist Completeness — tables and new ref.tax_categories entries
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extend ref.tax_categories with missing checklist document types
-- ---------------------------------------------------------------------------

INSERT INTO ref.tax_categories (category_id, category_nme, category_grp, description, is_deductible, sort_order)
VALUES
    (21, 'Managed Fund Tax Statement',           'Income',      'Annual tax statement from managed fund',             false, 21),
    (22, 'Employment Termination Payment',        'Income',      'ETP / lump sum payout from employer',                false, 22),
    (23, 'Government / Centrelink Payment',       'Government',  'Centrelink, pension, or other government payments',  false, 23),
    (24, 'Employee Share Scheme',                 'Income',      'ESS documents from employer',                        false, 24),
    (25, 'Foreign Income',                        'Income',      'Foreign income or overseas investment income',        false, 25),
    (26, 'Cryptocurrency Tax Report',             'Income',      'Annual crypto tax summary or Koinly report',         false, 26),
    (27, 'Business / Trust Distribution',         'Income',      'Distribution from business, trust, or partnership',  false, 27),
    (28, 'Motor Vehicle / Logbook',               'Deductions',  'Vehicle logbook, odometer records, fuel receipts',   true,  28),
    (29, 'Self-Education Expenses',               'Deductions',  'Course fees, textbooks, study materials',            true,  29),
    (30, 'Donations',                             'Deductions',  'Tax-deductible donation receipts',                   true,  30),
    (31, 'Work-Related Travel',                   'Deductions',  'Work travel expenses excluding home-to-work',        true,  31),
    (32, 'Tax Agent Fees',                        'Deductions',  'Prior year accounting / tax agent invoice',          true,  32),
    (33, 'Work-Related Assets',                   'Deductions',  'Assets purchased for work use (>$300 threshold)',    true,  33)
ON CONFLICT (category_id) DO NOTHING;


-- ---------------------------------------------------------------------------
-- 2. ref.tax_checklist_items
--    Master list of all checklist items from the tax agent's annual checklist.
--    DOCUMENT items are counted in % complete.
--    RESPONSE items store pre-fill data only (not in % complete).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ref.tax_checklist_items (
    item_id                SERIAL       PRIMARY KEY,
    section                TEXT         NOT NULL,
    item_name              TEXT         NOT NULL,
    description            TEXT,
    item_type              TEXT         NOT NULL CHECK (item_type IN ('DOCUMENT', 'RESPONSE')),
    always_required        BOOLEAN      NOT NULL DEFAULT false,
    applicability_group    TEXT,        -- short code e.g. 'INTEREST', 'WFH', 'CRYPTO'
    applicability_question TEXT,        -- human-readable question shown in email
    category_id            INTEGER      REFERENCES ref.tax_categories (category_id),
    response_format        TEXT         CHECK (response_format IN ('YES_NO', 'NUMERIC', 'TEXT')),
    sort_order             INTEGER,
    active                 BOOLEAN      NOT NULL DEFAULT true,
    CONSTRAINT chk_document_has_category
        CHECK (item_type <> 'DOCUMENT' OR category_id IS NOT NULL),
    CONSTRAINT chk_response_has_format
        CHECK (item_type <> 'RESPONSE' OR response_format IS NOT NULL)
);

COMMENT ON TABLE ref.tax_checklist_items IS
    'Master checklist items from tax agent annual form. DOCUMENT items tracked in % complete; RESPONSE items stored for form pre-fill only.';

COMMENT ON COLUMN ref.tax_checklist_items.applicability_group IS
    'Short code shared by items that share the same yes/no applicability question. One email answer covers all items in the group.';


-- ---------------------------------------------------------------------------
-- 3. ref.tax_checklist_responses
--    Per-item, per-FY user responses.
--    Upserted by CHECKLIST_RESPONSE webhook or manual DBeaver entry.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ref.tax_checklist_responses (
    response_id     SERIAL      PRIMARY KEY,
    item_id         INTEGER     NOT NULL REFERENCES ref.tax_checklist_items (item_id),
    fy_year         SMALLINT    NOT NULL,
    is_applicable   TEXT        NOT NULL DEFAULT 'UNKNOWN'
                    CHECK (is_applicable IN ('YES', 'NO', 'UNKNOWN')),
    response_value  TEXT,       -- RESPONSE items: numeric or text answer
    responded_at    TIMESTAMPTZ,
    source          TEXT        NOT NULL DEFAULT 'EMAIL'
                    CHECK (source IN ('EMAIL', 'DBEAVER', 'SYSTEM')),
    CONSTRAINT uq_checklist_response UNIQUE (item_id, fy_year)
);

COMMENT ON TABLE ref.tax_checklist_responses IS
    'User responses per checklist item per FY. is_applicable drives % complete for DOCUMENT items. response_value stores pre-fill data for RESPONSE items.';

COMMENT ON COLUMN ref.tax_checklist_responses.is_applicable IS
    'YES = item applies this FY (counted in denominator). NO = not applicable (excluded). UNKNOWN = questionnaire not yet answered.';
