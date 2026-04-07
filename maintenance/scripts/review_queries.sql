-- ============================================================
-- review_queries.sql  —  Tax Collector post-backfill review
-- Run in DBeaver against taxcollectordb (192.168.0.250:5432)
-- All queries are READ-ONLY.
-- ============================================================


-- ============================================================
-- 1. STATUS SUMMARY
--    Quick health-check: total records by review_status
-- ============================================================
SELECT
    review_status,
    COUNT(*)                          AS record_count,
    ROUND(AVG(confidence_score), 3)   AS avg_confidence,
    SUM(total_amount)                 AS total_amount_sum
FROM core.tax_documents
GROUP BY review_status
ORDER BY review_status;


-- ============================================================
-- 2. BREAKDOWN BY CATEGORY + STATUS
--    Which categories are AUTO_CONFIRMED vs NEEDS_REVIEW?
-- ============================================================
SELECT
    COALESCE(c.category_nme, '— uncategorised —') AS category,
    d.review_status,
    COUNT(*)                                       AS cnt,
    ROUND(AVG(d.confidence_score), 3)              AS avg_confidence
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
GROUP BY c.category_nme, d.review_status
ORDER BY c.category_nme, d.review_status;


-- ============================================================
-- 3. NEEDS_REVIEW LIST  (low-confidence, user action required)
--    Ordered: lowest confidence first, then by date
-- ============================================================
SELECT
    d.doc_id,
    d.review_status,
    ROUND(d.confidence_score, 3)                   AS confidence,
    COALESCE(c.category_nme, '—')                  AS category,
    d.fy_year,
    d.supplier_name,
    d.total_amount,
    d.document_date,
    d.subject,
    d.sender_email,
    d.reviewer_notes
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
WHERE d.review_status = 'NEEDS_REVIEW'
ORDER BY d.confidence_score ASC, d.document_date DESC;


-- ============================================================
-- 4. AUTO_CONFIRMED LIST  (high-confidence, spot-check)
--    Spot-check these before trusting them fully.
-- ============================================================
SELECT
    d.doc_id,
    ROUND(d.confidence_score, 3)                   AS confidence,
    COALESCE(c.category_nme, '—')                  AS category,
    d.fy_year,
    d.supplier_name,
    d.total_amount,
    d.document_date,
    d.subject,
    d.sender_email
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
WHERE d.review_status = 'AUTO_CONFIRMED'
ORDER BY d.confidence_score ASC, d.document_date DESC;


-- ============================================================
-- 5. AUTO_REJECTED LIST  (LLM flagged as not tax-relevant)
--    Review these to catch mis-classified documents.
-- ============================================================
SELECT
    d.doc_id,
    ROUND(d.confidence_score, 3)                   AS confidence,
    COALESCE(c.category_nme, '—')                  AS category,
    d.fy_year,
    d.supplier_name,
    d.total_amount,
    d.document_date,
    d.subject,
    d.sender_email
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
WHERE d.review_status = 'AUTO_REJECTED'
ORDER BY d.confidence_score DESC, d.document_date DESC;


-- ============================================================
-- 6. CONFIDENCE BAND HISTOGRAM
--    How are records distributed across confidence scores?
-- ============================================================
SELECT
    CASE
        WHEN confidence_score >= 0.90 THEN '0.90–1.00 (very high)'
        WHEN confidence_score >= 0.75 THEN '0.75–0.89 (high)'
        WHEN confidence_score >= 0.50 THEN '0.50–0.74 (medium)'
        WHEN confidence_score >= 0.25 THEN '0.25–0.49 (low)'
        ELSE                               '0.00–0.24 (very low)'
    END                                            AS confidence_band,
    COUNT(*)                                       AS cnt,
    STRING_AGG(DISTINCT review_status, ', ')       AS statuses
FROM core.tax_documents
GROUP BY 1
ORDER BY 1 DESC;


-- ============================================================
-- 7. BY SUPPLIER  (spot mis-classifications at a glance)
--    Great for bulk decisions: "all Origin Energy = CONFIRMED"
-- ============================================================
with cte_a as
(
SELECT
    COALESCE(supplier_name, '— unknown —')         AS supplier,
    --subject,
    --sender_email,
    COALESCE(c.category_nme, '—')                  AS category,
    COUNT(*)                                       AS record_count,
    ROUND(AVG(d.confidence_score), 3)              AS avg_confidence,
    MIN(d.document_date)                           AS earliest,
    MAX(d.document_date)                           AS latest,
    SUM(d.total_amount)                            AS total_amount,
    STRING_AGG(DISTINCT d.review_status, ', ')     AS statuses
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
GROUP BY supplier_name, c.category_nme --,subject, sender_email
ORDER BY record_count DESC, supplier
)
select * from cte_a where supplier = 'Moose Mobile';


select * from core.tax_documents d
where supplier_name = 'Moose Mobile' order by received_at



-- ============================================================
-- 8. BY FY YEAR  (validate backfill coverage)
-- ============================================================
SELECT
    fy_year,
    COUNT(*)                                       AS record_count,
    ROUND(AVG(confidence_score), 3)                AS avg_confidence,
    SUM(total_amount)                              AS total_amount,
    STRING_AGG(DISTINCT review_status, ', ')       AS statuses
FROM core.tax_documents
GROUP BY fy_year
ORDER BY fy_year DESC;


-- ============================================================
-- 9. POTENTIAL DUPLICATES
--    Same supplier + document_date + total_amount appearing twice
-- ============================================================
SELECT
    supplier_name,
    document_date,
    total_amount,
    COUNT(*)    AS copies,
    STRING_AGG(doc_id::text, ', ') AS doc_ids
FROM core.tax_documents
WHERE supplier_name IS NOT NULL
  AND document_date IS NOT NULL
  AND total_amount IS NOT NULL
GROUP BY supplier_name, document_date, total_amount
HAVING COUNT(*) > 1
ORDER BY copies DESC, supplier_name;


-- ============================================================
-- 10. SINGLE RECORD LOOKUP  (by doc_id — for detailed review)
--     Replace <doc_id> with the actual value.
-- ============================================================
SELECT
    d.*,
    c.category_nme
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
WHERE d.doc_id = <doc_id>;
