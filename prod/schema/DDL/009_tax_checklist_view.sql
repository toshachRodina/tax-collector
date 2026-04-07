-- =============================================================================
-- 009_tax_checklist_view.sql
-- mart.vw_checklist_completeness
-- Joins checklist items + FY responses + confirmed core.tax_documents.
-- Drives Metabase % complete dashboard.
-- =============================================================================

CREATE OR REPLACE VIEW mart.vw_checklist_completeness AS

WITH doc_counts AS (
    -- Count confirmed documents per category per FY
    SELECT
        d.tax_category_id,
        d.fy_year,
        COUNT(*) AS doc_count
    FROM core.tax_documents d
    WHERE d.review_status IN ('CONFIRMED', 'AUTO_CONFIRMED')
    GROUP BY d.tax_category_id, d.fy_year
)

SELECT
    i.item_id,
    i.section,
    i.item_name,
    i.description,
    i.item_type,
    i.always_required,
    i.applicability_group,
    i.applicability_question,
    tc.category_nme,
    tc.category_grp,
    tc.is_deductible,

    r.fy_year,
    r.is_applicable,
    r.response_value,
    r.responded_at,

    COALESCE(dc.doc_count, 0) AS doc_count,

    -- Status logic
    CASE
        WHEN i.item_type = 'RESPONSE'
            THEN 'N/A'
        WHEN i.always_required OR r.is_applicable = 'YES'
            THEN CASE
                     WHEN COALESCE(dc.doc_count, 0) > 0 THEN 'SATISFIED'
                     ELSE 'MISSING'
                 END
        WHEN r.is_applicable = 'NO'
            THEN 'NOT_APPLICABLE'
        ELSE
            'UNKNOWN'   -- questionnaire not yet answered
    END AS status,

    -- In-scope flag: item counts toward % complete denominator
    CASE
        WHEN i.item_type = 'DOCUMENT'
             AND (i.always_required OR r.is_applicable = 'YES')
        THEN true
        ELSE false
    END AS in_scope

FROM ref.tax_checklist_items i
LEFT JOIN ref.tax_checklist_responses r
       ON r.item_id = i.item_id
LEFT JOIN ref.tax_categories tc
       ON tc.category_id = i.category_id
LEFT JOIN doc_counts dc
       ON dc.tax_category_id = i.category_id
      AND dc.fy_year = r.fy_year
WHERE i.active = true;

COMMENT ON VIEW mart.vw_checklist_completeness IS
    'Per-item checklist status for each FY. Use in_scope=true AND item_type=DOCUMENT rows to compute % complete. status: SATISFIED | MISSING | NOT_APPLICABLE | UNKNOWN | N/A.';
