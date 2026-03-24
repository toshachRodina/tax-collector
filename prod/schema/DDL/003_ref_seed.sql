-- =============================================================================
-- 003_ref_seed.sql — Reference data seed
-- Run as taxcollectorusr against taxcollectordb
-- Idempotent: uses INSERT ... ON CONFLICT DO NOTHING
-- =============================================================================

\c taxcollectordb
SET search_path TO ref, public;

-- ---------------------------------------------------------------------------
-- ref.fy_periods — Australian financial years
-- ---------------------------------------------------------------------------
INSERT INTO ref.fy_periods (fy_year, fy_label, start_date, end_date, lodgement_deadline, is_current)
VALUES
    (2023, 'FY2023', '2022-07-01', '2023-06-30', '2023-10-31', FALSE),
    (2024, 'FY2024', '2023-07-01', '2024-06-30', '2024-10-31', FALSE),
    (2025, 'FY2025', '2024-07-01', '2025-06-30', '2025-10-31', TRUE),
    (2026, 'FY2026', '2025-07-01', '2026-06-30', '2026-10-31', FALSE)
ON CONFLICT (fy_year) DO NOTHING;

-- ---------------------------------------------------------------------------
-- ref.tax_categories — ATO-aligned document categories
-- ---------------------------------------------------------------------------
INSERT INTO ref.tax_categories (category_nme, category_grp, description, is_deductible, ato_reference, sort_order)
VALUES
    -- Income
    ('Payment Summary / Group Certificate', 'Income',
        'Annual income statement from employer', FALSE, 'Item 1', 1),
    ('Bank Interest Statement', 'Income',
        'Interest earned on savings accounts', FALSE, 'Item 10', 2),
    ('Dividend Statement', 'Income',
        'Share dividend payments', FALSE, 'Item 11', 3),
    ('Share Sale / CGT Event', 'Income',
        'Capital gains from share disposals', FALSE, 'Item 18', 4),

    -- Deductions — Work-related
    ('Work From Home — Internet', 'Deductions',
        'Home internet bill (WFH portion deductible)', TRUE, 'D5', 10),
    ('Work From Home — Electricity/Gas', 'Deductions',
        'Utility bill (WFH portion deductible)', TRUE, 'D5', 11),
    ('Work From Home — Insurance', 'Deductions',
        'Home & contents insurance (home office portion)', TRUE, 'D5', 12),
    ('Technology Equipment', 'Deductions',
        'Work-related tech: keyboards, mice, hard drives, monitors', TRUE, 'D3', 13),
    ('Software & Subscriptions', 'Deductions',
        'Work-related software, LLM subscriptions, productivity tools', TRUE, 'D5', 14),
    ('Professional Development', 'Deductions',
        'Training courses, certifications, conferences', TRUE, 'D4', 15),
    ('Professional Memberships', 'Deductions',
        'Industry body memberships and subscriptions', TRUE, 'D5', 16),

    -- Deductions — Insurance
    ('Income Protection Insurance', 'Deductions',
        'Premiums for income protection policy — fully deductible', TRUE, 'D12', 20),

    -- Property
    ('Rental Income Statement', 'Property',
        'Rental property income statements', FALSE, 'Item 21', 30),
    ('Property Depreciation Schedule', 'Property',
        'Depreciation report from quantity surveyor', TRUE, 'Item 21', 31),

    -- Government
    ('ATO Notice / Assessment', 'Government',
        'Tax assessment, payment or refund notice from ATO', FALSE, NULL, 40),
    ('HECS/HELP Statement', 'Government',
        'Student loan balance and repayment statement', FALSE, 'Item 14', 41),

    -- Super
    ('Superannuation Statement', 'Super',
        'Annual super fund statement', FALSE, NULL, 50),
    ('Super Contribution Notice', 'Super',
        'Voluntary super contribution confirmation', FALSE, NULL, 51),

    -- Health
    ('Private Health Insurance Statement', 'Health',
        'Annual PHI statement for Medicare Levy Surcharge assessment', FALSE, 'Item M2', 60),

    -- Other
    ('Invoice / Receipt — Other', 'Other',
        'Unclassified invoice or receipt requiring manual review', FALSE, NULL, 99)

ON CONFLICT (category_nme) DO NOTHING;

-- ---------------------------------------------------------------------------
-- ref.transaction_categories — Spending categories
-- ---------------------------------------------------------------------------
INSERT INTO ref.transaction_categories
    (category_nme, subcategory_nme, is_income, is_tax_relevant, is_deductible, sort_order)
VALUES
    -- Income
    ('Income', 'Salary/Wages',       TRUE,  TRUE,  FALSE, 1),
    ('Income', 'Freelance/Contract', TRUE,  TRUE,  FALSE, 2),
    ('Income', 'Interest',           TRUE,  TRUE,  FALSE, 3),
    ('Income', 'Dividends',          TRUE,  TRUE,  FALSE, 4),
    ('Income', 'Other',              TRUE,  TRUE,  FALSE, 5),

    -- Housing
    ('Housing', 'Mortgage/Rent',     FALSE, FALSE, FALSE, 10),
    ('Housing', 'Rates & Strata',    FALSE, FALSE, FALSE, 11),
    ('Housing', 'Electricity/Gas',   FALSE, TRUE,  TRUE,  12),
    ('Housing', 'Water',             FALSE, FALSE, FALSE, 13),
    ('Housing', 'Internet',          FALSE, TRUE,  TRUE,  14),
    ('Housing', 'Insurance',         FALSE, TRUE,  TRUE,  15),

    -- Food
    ('Food', 'Groceries',            FALSE, FALSE, FALSE, 20),
    ('Food', 'Dining Out',           FALSE, FALSE, FALSE, 21),
    ('Food', 'Takeaway/Delivery',    FALSE, FALSE, FALSE, 22),

    -- Transport
    ('Transport', 'Fuel',            FALSE, FALSE, FALSE, 30),
    ('Transport', 'Public Transport',FALSE, FALSE, FALSE, 31),
    ('Transport', 'Parking',         FALSE, FALSE, FALSE, 32),
    ('Transport', 'Car Insurance',   FALSE, FALSE, FALSE, 33),
    ('Transport', 'Car Registration',FALSE, FALSE, FALSE, 34),
    ('Transport', 'Tolls',           FALSE, FALSE, FALSE, 35),

    -- Health
    ('Health', 'Private Health Insurance', FALSE, FALSE, FALSE, 40),
    ('Health', 'Medical/Dental',     FALSE, FALSE, FALSE, 41),
    ('Health', 'Pharmacy',           FALSE, FALSE, FALSE, 42),
    ('Health', 'Optical',            FALSE, FALSE, FALSE, 43),

    -- Insurance
    ('Insurance', 'Income Protection', FALSE, TRUE,  TRUE,  50),
    ('Insurance', 'Life Insurance',    FALSE, FALSE, FALSE, 51),
    ('Insurance', 'Other',             FALSE, FALSE, FALSE, 52),

    -- Technology
    ('Technology', 'Hardware',              FALSE, TRUE, TRUE,  60),
    ('Technology', 'Software/Subscriptions',FALSE, TRUE, TRUE,  61),
    ('Technology', 'Mobile Phone',          FALSE, FALSE, FALSE, 62),

    -- Professional
    ('Professional', 'Training & Education', FALSE, TRUE, TRUE, 70),
    ('Professional', 'Memberships',          FALSE, TRUE, TRUE, 71),
    ('Professional', 'Books & Resources',    FALSE, TRUE, TRUE, 72),

    -- Entertainment & Lifestyle
    ('Entertainment', 'Streaming Services', FALSE, FALSE, FALSE, 80),
    ('Entertainment', 'Hobbies',            FALSE, FALSE, FALSE, 81),
    ('Entertainment', 'Social/Dining',      FALSE, FALSE, FALSE, 82),
    ('Entertainment', 'Sport & Fitness',    FALSE, FALSE, FALSE, 83),

    -- Savings & Investments
    ('Savings', 'Savings Transfer',    FALSE, FALSE, FALSE, 90),
    ('Savings', 'Investment Purchase', FALSE, FALSE, FALSE, 91),
    ('Savings', 'Super Contribution',  FALSE, FALSE, FALSE, 92),

    -- Other
    ('Other', 'ATM/Cash',          FALSE, FALSE, FALSE, 99),
    ('Other', 'Fees & Charges',    FALSE, FALSE, FALSE, 99),
    ('Other', 'Uncategorised',     FALSE, FALSE, FALSE, 99)

ON CONFLICT (category_nme, COALESCE(subcategory_nme, '')) DO NOTHING;

-- ---------------------------------------------------------------------------
-- ref.statement_providers — CSV format configs
-- IMPORTANT: Verify column names against real sample CSVs before first use.
-- ---------------------------------------------------------------------------
INSERT INTO ref.statement_providers
    (provider_nme, date_col, date_format, amount_col, debit_col, credit_col,
     description_col, balance_col, skip_rows, notes)
VALUES
    ('NAB',
        'Date', '%d %b %y',
        'Amount', NULL, NULL,
        'Transaction Details', 'Balance', 0,
        'NAB CSV columns (verified 2026-03-24): Date, Amount, Account Number, '
        'Transaction Type, Transaction Details, Balance, Category, Merchant Name, Processed On. '
        'Single Amount column — negative = debit, positive = credit. '
        'Date format: "24 Mar 26" = %d %b %y. '
        'Extra cols (Transaction Type, Category, Merchant Name) captured in raw_json.'),

    ('Bendigo',
        'Date', '%d/%m/%Y',
        NULL, 'Debit', 'Credit',
        'Description', 'Balance', 0,
        'Bendigo Bank CSV: separate Debit/Credit columns. '
        'Canonical amount = Credit - Debit (debits are positive in Debit col). '
        'VERIFY column names against a real Bendigo export before first use.'),

    ('CommSec',
        'Date', '%d/%m/%Y',
        NULL, 'Debit', 'Credit',
        'Description', 'Balance', 0,
        'CommSec transaction CSV. '
        'NOTE: Share trade CSV uses a different format — handled by share_transactions ingestor. '
        'VERIFY against real sample before first use.')

ON CONFLICT (provider_nme) DO NOTHING;

-- ---------------------------------------------------------------------------
-- ref.accounts — Known accounts (add real BSB/account numbers manually via UI)
-- Placeholders — update with real details outside the repo.
-- ---------------------------------------------------------------------------
INSERT INTO ref.accounts (account_nme, provider, account_type, currency, is_active, csv_provider_id, notes)
VALUES
    ('NAB Transaction Account', 'NAB', 'TRANSACTION', 'AUD', TRUE,
        (SELECT provider_id FROM ref.statement_providers WHERE provider_nme = 'NAB'),
        'Primary everyday transaction account'),
    ('NAB Savings Account', 'NAB', 'SAVINGS', 'AUD', TRUE,
        (SELECT provider_id FROM ref.statement_providers WHERE provider_nme = 'NAB'),
        'High interest savings account'),
    ('Bendigo Bank Account', 'Bendigo', 'TRANSACTION', 'AUD', TRUE,
        (SELECT provider_id FROM ref.statement_providers WHERE provider_nme = 'Bendigo'),
        'Bendigo transaction account'),
    ('Share Holdings', 'CommSec', 'INVESTMENT', 'AUD', TRUE,
        (SELECT provider_id FROM ref.statement_providers WHERE provider_nme = 'CommSec'),
        'Brokerage account — share holdings and transactions'),
    ('Superannuation', 'TBD', 'SUPER', 'AUD', TRUE, NULL,
        'Super fund — provider and CSV format TBD. Placeholder for v2.')
ON CONFLICT DO NOTHING;

\echo '✓ 003_ref_seed.sql complete'
