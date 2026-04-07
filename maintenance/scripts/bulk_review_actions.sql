-- ============================================================
-- bulk_review_actions.sql  —  Tax Collector review DML
-- Run in DBeaver against taxcollectordb (192.168.0.250:5432)
--
-- RULES:
--   • Every UPDATE has an explicit WHERE clause — no bulk-without-filter
--   • reviewed_at is stamped automatically by trigger trg_tax_docs_reviewed_at
--     when review_status changes — do NOT set it manually
--   • Valid review_status values:
--       PENDING        — not yet processed by merge workflow
--       NEEDS_REVIEW   — low confidence, awaiting user decision
--       AUTO_CONFIRMED — high confidence, accepted by system
--       AUTO_REJECTED  — LLM flagged as not tax-relevant
--       CONFIRMED      — user accepted
--       REJECTED       — user rejected
-- ============================================================


-- ============================================================
-- A. SINGLE RECORD  —  accept or reject by doc_id
-- ============================================================

-- Accept one record
UPDATE core.tax_documents
SET review_status  = 'CONFIRMED',
    reviewer_notes = 'Manually confirmed'     -- optional: replace with your note
WHERE doc_id = <doc_id>;

-- Reject one record
UPDATE core.tax_documents
SET review_status  = 'REJECTED',
    reviewer_notes = 'Not tax-relevant'       -- optional: replace with your note
WHERE doc_id = <doc_id>;


-- ============================================================
-- B. BULK ACCEPT  —  all records for a specific supplier
--    Use query 7 from review_queries.sql to find supplier names
-- ============================================================
UPDATE core.tax_documents
SET review_status  = 'CONFIRMED',
    reviewer_notes = 'Bulk confirmed — known supplier'
WHERE LOWER(supplier_name) = LOWER('<Supplier Name Here>')
  AND review_status IN ('NEEDS_REVIEW', 'AUTO_CONFIRMED');


-- ============================================================
-- C. BULK REJECT  —  all records for a specific supplier
-- ============================================================
UPDATE core.tax_documents
SET review_status  = 'REJECTED',
    reviewer_notes = 'Bulk rejected — not tax-relevant supplier'
WHERE LOWER(supplier_name) = LOWER('<Supplier Name Here>')
  AND review_status IN ('NEEDS_REVIEW', 'AUTO_CONFIRMED', 'AUTO_REJECTED');


-- ============================================================
-- D. BULK ACCEPT  —  all AUTO_CONFIRMED for a category
--    Use only if you trust the category is reliably classified.
-- ============================================================
UPDATE core.tax_documents
SET review_status  = 'CONFIRMED',
    reviewer_notes = 'Bulk confirmed — high confidence category'
WHERE tax_category_id = (
    SELECT category_id FROM ref.tax_categories
    WHERE category_nme = '<Exact Category Name Here>'
)
  AND review_status = 'AUTO_CONFIRMED'
  AND confidence_score >= 0.85;


-- ============================================================
-- E. BULK ACCEPT  —  by confidence threshold for a FY year
--    Accept everything above 0.90 confidence for a given year.
--    Safer threshold for unreviewed bulk accept.
-- ============================================================
UPDATE core.tax_documents
SET review_status  = 'CONFIRMED',
    reviewer_notes = 'Bulk confirmed — confidence >= 0.90'
WHERE confidence_score >= 0.90
  AND fy_year = <fy_year>                     -- e.g. 2025
  AND review_status = 'AUTO_CONFIRMED';


-- ============================================================
-- F. PROMOTE AUTO_REJECTED  —  rescue a mis-classified record
--    LLM said not-relevant but you disagree — override it.
-- ============================================================
UPDATE core.tax_documents
SET review_status  = 'CONFIRMED',
    reviewer_notes = 'Rescued — LLM incorrectly rejected this document'
WHERE doc_id = <doc_id>
  AND review_status = 'AUTO_REJECTED';


-- ============================================================
-- G. CORRECT CATEGORY  —  change category_id on a record
--    Look up category_id values from ref.tax_categories first.
-- ============================================================
UPDATE core.tax_documents
SET tax_category_id = (
    SELECT category_id FROM ref.tax_categories
    WHERE category_nme = '<Correct Category Name>'
)
WHERE doc_id = <doc_id>;


-- ============================================================
-- H. ADD / UPDATE REVIEWER NOTES  —  without changing status
-- ============================================================
UPDATE core.tax_documents
SET reviewer_notes = '<Your note here>'
WHERE doc_id = <doc_id>;


-- ============================================================
-- I. VERIFY your changes
--    Run after any bulk update to confirm counts look right.
-- ============================================================
SELECT
    review_status,
    COUNT(*) AS record_count
FROM core.tax_documents
GROUP BY review_status
ORDER BY review_status;
