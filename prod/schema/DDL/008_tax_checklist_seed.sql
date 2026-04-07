-- =============================================================================
-- 008_tax_checklist_seed.sql
-- Seed ref.tax_checklist_items with all items from the tax agent's
-- 2024/25 Individual Tax Return Checklist.
-- Safe to re-run — uses ON CONFLICT DO NOTHING.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- DOCUMENT items (counted in % complete)
-- ---------------------------------------------------------------------------

INSERT INTO ref.tax_checklist_items
    (item_id, section, item_name, description, item_type,
     always_required, applicability_group, applicability_question, category_id, sort_order)
VALUES

-- INCOME --------------------------------------------------------------------
(1,  'Income', 'Payment Summary / PAYG from employer',
     'Payment summary or income statement from each employer.',
     'DOCUMENT', true, NULL, NULL, 1, 10),

(2,  'Income', 'Bank interest statement',
     'Interest income from all bank or savings accounts.',
     'DOCUMENT', false, 'INTEREST',
     'Did you earn interest income from bank or savings accounts this year?', 2, 20),

(3,  'Income', 'Dividend statement',
     'Dividend or distribution statements from shares or ETFs.',
     'DOCUMENT', false, 'SHARES',
     'Did you receive dividends or distributions from shares or managed funds?', 3, 30),

(4,  'Income', 'Share sale / CGT event',
     'Purchase and sale contracts for any shares or investments sold.',
     'DOCUMENT', false, 'CGT',
     'Did you sell any shares, ETFs, or other investments this year?', 4, 40),

(5,  'Income', 'Managed fund annual tax statement',
     'Annual tax statement from managed fund provider.',
     'DOCUMENT', false, 'MANAGED_FUND',
     'Did you receive income from a managed fund?', 21, 50),

(6,  'Income', 'Employment termination payment (ETP)',
     'ETP or lump sum payment documents from employer.',
     'DOCUMENT', false, 'ETP',
     'Did you finish employment or receive a lump sum payout this year?', 22, 60),

(7,  'Income', 'Government / Centrelink payments',
     'Centrelink, pension, or other government payment summaries.',
     'DOCUMENT', false, 'CENTRELINK',
     'Did you receive Centrelink or any government payments this year?', 23, 70),

(8,  'Income', 'Employee Share Scheme (ESS) documents',
     'ESS statements or discounts reported for tax.',
     'DOCUMENT', false, 'ESS',
     'Are you involved in an Employee Share Scheme?', 24, 80),

(9,  'Income', 'Foreign income',
     'Foreign income or overseas investment income documentation.',
     'DOCUMENT', false, 'FOREIGN',
     'Did you earn foreign income or hold overseas investments this year?', 25, 90),

(10, 'Income', 'Cryptocurrency annual tax report',
     'Annual crypto tax summary or Koinly CGT report.',
     'DOCUMENT', false, 'CRYPTO',
     'Did you trade, sell, swap, or hold cryptocurrency this year?', 26, 100),

(11, 'Income', 'Business / trust / partnership distribution',
     'Distribution statement from a business, trust, or partnership.',
     'DOCUMENT', false, 'BUSINESS',
     'Did you receive a distribution from a business, trust, or partnership?', 27, 110),

-- DEDUCTIONS — Work From Home -----------------------------------------------
(12, 'Deductions', 'Work from home — electricity/gas bills',
     'Energy bills for work-from-home claim (fixed rate or actual cost method).',
     'DOCUMENT', false, 'WFH',
     'Did you work from home this year?', 6, 200),

(13, 'Deductions', 'Work from home — internet bills',
     'Internet plan invoices for work-from-home claim.',
     'DOCUMENT', false, 'WFH',
     'Did you work from home this year?', 5, 210),

(14, 'Deductions', 'Work from home — home/contents insurance',
     'Insurance policy documents for work-from-home actual cost claim.',
     'DOCUMENT', false, 'WFH',
     'Did you work from home this year?', 7, 220),

-- DEDUCTIONS — Equipment & Tech ----------------------------------------------
(15, 'Deductions', 'Technology equipment receipts',
     'Receipts for laptops, monitors, or other work-related tech.',
     'DOCUMENT', false, 'TECH',
     'Did you purchase work-related technology or equipment this year?', 8, 300),

(16, 'Deductions', 'Software & subscription receipts',
     'Receipts for work-related software or online subscriptions.',
     'DOCUMENT', false, 'TECH',
     'Did you purchase work-related technology or equipment this year?', 9, 310),

-- DEDUCTIONS — Professional --------------------------------------------------
(17, 'Deductions', 'Professional development / self-education receipts',
     'Course fees, textbooks, or study material receipts.',
     'DOCUMENT', false, 'SELF_ED',
     'Did you have self-education or professional development expenses?', 10, 400),

(18, 'Deductions', 'Professional membership fees',
     'Receipts for work-related professional association memberships.',
     'DOCUMENT', false, 'PROF_MEM',
     'Did you pay work-related professional membership fees?', 11, 410),

-- DEDUCTIONS — Other ---------------------------------------------------------
(19, 'Deductions', 'Income protection insurance (outside super)',
     'Income protection insurance policy or premium statement.',
     'DOCUMENT', false, 'INCOME_PROT',
     'Do you have income protection insurance paid outside your super fund?', 12, 500),

(20, 'Deductions', 'Motor vehicle / logbook records',
     'Logbook, odometer readings, or vehicle expense receipts.',
     'DOCUMENT', false, 'VEHICLE',
     'Did you use your personal vehicle for work purposes this year?', 28, 510),

(21, 'Deductions', 'Self-education expense receipts',
     'Receipts for courses, textbooks, or study directly related to current work.',
     'DOCUMENT', false, 'SELF_ED',
     'Did you have self-education or professional development expenses?', 29, 520),

(22, 'Deductions', 'Donation receipts',
     'Receipts for tax-deductible charitable donations.',
     'DOCUMENT', false, 'DONATIONS',
     'Did you make any tax-deductible donations this year?', 30, 530),

(23, 'Deductions', 'Work-related travel expenses',
     'Receipts or records for work travel (excluding home-to-work commute).',
     'DOCUMENT', false, 'WORK_TRAVEL',
     'Did you incur work-related travel costs (flights, accommodation, etc.)?', 31, 540),

(24, 'Deductions', 'Tax agent fees — prior year invoice',
     'Invoice from tax agent for prior year return preparation.',
     'DOCUMENT', true, NULL, NULL, 32, 550),

(25, 'Deductions', 'Work-related assets purchased',
     'Receipts for assets purchased for work use (e.g., tools, equipment).',
     'DOCUMENT', false, 'WORK_ASSETS',
     'Did you purchase any work-related assets this year?', 33, 560),

-- PROPERTY -------------------------------------------------------------------
(26, 'Property', 'Rental income statement',
     'Annual rental income statement from property manager or directly.',
     'DOCUMENT', false, 'RENTAL',
     'Do you own a rental property?', 13, 600),

(27, 'Property', 'Property depreciation schedule',
     'Quantity surveyor depreciation schedule for rental property.',
     'DOCUMENT', false, 'RENTAL',
     'Do you own a rental property?', 14, 610),

-- SUPER ----------------------------------------------------------------------
(28, 'Super', 'Superannuation annual statement',
     'Annual statement from super fund showing contributions and balance.',
     'DOCUMENT', false, 'SUPER',
     'Do you want to review super contributions or claim a deduction for personal contributions?', 17, 700),

(29, 'Super', 'Super contribution notice (s290-170)',
     'Notice of intent to claim personal super contributions as a deduction.',
     'DOCUMENT', false, 'SUPER',
     'Do you want to review super contributions or claim a deduction for personal contributions?', 18, 710),

-- HEALTH & GOVERNMENT --------------------------------------------------------
(30, 'Health', 'Private health insurance statement',
     'Annual private health insurance tax statement from insurer.',
     'DOCUMENT', false, 'HEALTH',
     'Do you have private health insurance (hospital or combined cover, not extras only)?', 19, 800),

(31, 'Government', 'ATO notice / assessment',
     'Any ATO correspondence or previous year notice of assessment.',
     'DOCUMENT', false, 'ATO',
     'Did you receive any correspondence or notices from the ATO this year?', 15, 900),

(32, 'Government', 'HECS-HELP / StudyAssist statement',
     'ATO or MyGov HECS-HELP loan balance statement.',
     'DOCUMENT', false, 'HECS',
     'Do you have a HECS-HELP, VSL, SFSS, SSL, or TSL debt?', 16, 910)

ON CONFLICT (item_id) DO NOTHING;


-- ---------------------------------------------------------------------------
-- RESPONSE items (NOT counted in % complete — stored for form pre-fill)
-- ---------------------------------------------------------------------------

INSERT INTO ref.tax_checklist_items
    (item_id, section, item_name, description, item_type,
     always_required, applicability_group, applicability_question, category_id, response_format, sort_order)
VALUES

-- Profile
(100, 'Profile', 'Do you have a MyGov account?',
      'Most ATO mail now goes to myGov inbox.',
      'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1000),

(101, 'Profile', 'Are you a foreign resident or working holiday maker?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1010),

-- Work From Home
(110, 'Work From Home', 'Total hours worked from home during the year',
      'Required for Fixed Rate Method @ 70c/hr.',
      'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1100),

(111, 'Work From Home', 'Internet plan monthly cost ($)',
      'For Actual Cost Method.',
      'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1110),

(112, 'Work From Home', 'Internet work-use percentage (%)',
      'For Actual Cost Method.',
      'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1120),

(113, 'Work From Home', 'Mobile phone monthly cost ($)',
      'For Actual Cost Method.',
      'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1130),

(114, 'Work From Home', 'Mobile phone work-use percentage (%)',
      'For Actual Cost Method.',
      'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1140),

-- Motor Vehicle
(120, 'Motor Vehicle', 'Odometer reading as at 01/07/2024',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1200),

(121, 'Motor Vehicle', 'Odometer reading as at 30/06/2025',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1210),

(122, 'Motor Vehicle', 'Total work-related kilometres',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1220),

(123, 'Motor Vehicle', 'Is it a zero-emission electric vehicle?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1230),

(124, 'Motor Vehicle', 'Is it a plug-in hybrid electric vehicle?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1240),

-- Self-Education
(130, 'Self-Education', 'Total study hours during the year',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1300),

-- Financial
(140, 'Financial', 'Did you pay child support this year?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1400),

(141, 'Financial', 'Child support amount paid ($)',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1410),

(142, 'Financial', 'Spouse taxable income ($)',
      'Only required if your spouse''s return is not prepared by the same agent.',
      'RESPONSE', false, NULL, NULL, NULL, 'NUMERIC', 1420),

-- Medicare
(150, 'Medicare', 'Eligible for Medicare levy exemption (part or full year)?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1500),

-- Health
(160, 'Health', 'Is health insurance policy extras-only cover?',
      'Extras-only policies do not attract the Medicare Levy Surcharge offset.',
      'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1600),

-- Estate (not tax-relevant for % complete but good to capture)
(170, 'Estate', 'Have you appointed a Power of Attorney (POA)?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1700),

(171, 'Estate', 'Have you nominated a beneficiary for life insurance?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1710),

(172, 'Estate', 'Have you chosen an Executor?',
      NULL, 'RESPONSE', false, NULL, NULL, NULL, 'YES_NO', 1720)

ON CONFLICT (item_id) DO NOTHING;


-- ---------------------------------------------------------------------------
-- Seed default UNKNOWN responses for FY2025 for all items
-- ---------------------------------------------------------------------------

INSERT INTO ref.tax_checklist_responses (item_id, fy_year, is_applicable, source)
SELECT item_id, 2025, 'UNKNOWN', 'SYSTEM'
FROM   ref.tax_checklist_items
ON CONFLICT (item_id, fy_year) DO NOTHING;
