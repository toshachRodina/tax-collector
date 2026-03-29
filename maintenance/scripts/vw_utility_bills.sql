-- Utility bill mart views for solar battery ROI and energy usage analysis.
-- Run via: docker exec -i postgres psql -U n8nusr -d taxcollectordb < /mnt/disk2/...
-- Idempotent: CREATE OR REPLACE VIEW

-- ---------------------------------------------------------------------------
-- mart.vw_utility_bills
-- One row per utility bill. Includes the full line_items JSONB array.
-- Filtered to electricity/gas/internet categories only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_utility_bills AS
SELECT
    d.doc_id,
    d.source_id,
    d.subject,
    d.supplier_name,
    d.account_ref,
    d.supply_address,
    d.billing_start,
    d.billing_end,
    d.document_date,
    d.total_amount,
    d.gst_amount,
    d.line_items,
    c.category_nme,
    f.fy_label,
    f.fy_year,
    d.review_status,
    d.filed_path,
    d.confidence_score,
    d.created_at
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON d.tax_category_id = c.category_id
LEFT JOIN ref.fy_periods     f ON d.fy_year = f.fy_year
WHERE c.category_nme IN (
    'Work From Home — Electricity/Gas',
    'Work From Home — Internet'
)
ORDER BY d.billing_start NULLS LAST, d.supplier_name;

COMMENT ON VIEW mart.vw_utility_bills IS
    'One row per utility bill (electricity, gas, internet). '
    'line_items JSONB array contains granular charge detail (kWh, rates, solar feed-in). '
    'Use for solar battery ROI modelling and WFH deduction tracking.';

-- ---------------------------------------------------------------------------
-- mart.vw_utility_line_items
-- Expanded line items — one row per charge line per bill.
-- Use for time-series analysis: peak kWh trends, solar feed-in history, etc.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.vw_utility_line_items AS
SELECT
    d.doc_id,
    d.supplier_name,
    d.account_ref,
    d.supply_address,
    d.billing_start,
    d.billing_end,
    f.fy_label,
    f.fy_year,
    c.category_nme,
    -- Expanded line item fields
    li.ordinality                              AS line_num,
    li.value->>'description'                   AS description,
    li.value->>'period'                        AS period,
    NULLIF(li.value->>'quantity', '')::numeric  AS quantity,
    li.value->>'unit'                           AS unit,
    NULLIF(li.value->>'rate', '')::numeric      AS rate,
    NULLIF(li.value->>'amount', '')::numeric    AS amount,
    d.review_status,
    d.created_at
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c  ON d.tax_category_id = c.category_id
LEFT JOIN ref.fy_periods     f  ON d.fy_year = f.fy_year
CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(d.line_items, '[]'::jsonb)
) WITH ORDINALITY AS li(value, ordinality)
WHERE c.category_nme IN (
    'Work From Home — Electricity/Gas',
    'Work From Home — Internet'
)
  AND jsonb_array_length(COALESCE(d.line_items, '[]'::jsonb)) > 0
ORDER BY d.billing_start NULLS LAST, d.supplier_name, li.ordinality;

COMMENT ON VIEW mart.vw_utility_line_items IS
    'Expanded utility bill line items — one row per charge line. '
    'Use to aggregate kWh consumption, solar feed-in credits, and daily charges over time. '
    'Filter by description ILIKE ''%peak%'' or ''%solar%'' for specific analysis.';
