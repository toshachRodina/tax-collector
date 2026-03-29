-- Safe date cast: returns NULL for invalid dates (e.g. 2026-01-00 from LLM)
CREATE OR REPLACE FUNCTION core.safe_to_date(p_text text)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $f$
BEGIN
  IF p_text IS NULL OR p_text IN ('', 'null') THEN
    RETURN NULL;
  END IF;
  BEGIN
    RETURN p_text::date;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$f$;

CREATE OR REPLACE PROCEDURE core.sp_merge_tax_documents(IN p_batch_id integer DEFAULT NULL::integer)
LANGUAGE plpgsql AS $procedure$
DECLARE
    v_merged   INTEGER := 0;
    v_skipped  INTEGER := 0;
BEGIN
    WITH unprocessed AS (
        SELECT *
        FROM landing.tax_documents
        WHERE is_processed = FALSE
          AND (p_batch_id IS NULL OR batch_id = p_batch_id)
    ),
    ranked AS (
        SELECT
            *,
            ROW_NUMBER() OVER (
                PARTITION BY source_type, source_id
                ORDER BY COALESCE(file_size_bytes, 0) DESC,
                         COALESCE(file_name, '') ASC
            ) AS rn
        FROM unprocessed
    ),
    primary_docs AS (
        SELECT * FROM ranked WHERE rn = 1
    ),
    merged AS (
        INSERT INTO core.tax_documents (
            source_type, source_id, subject, sender_email, received_at,
            fy_year, file_name, file_ext, file_size_bytes, content_preview,
            tax_category_id, is_deductible, deductible_amount,
            confidence_score, classification_model, review_status, batch_id,
            supplier_name, account_ref, supply_address,
            document_date, billing_start, billing_end,
            total_amount, gst_amount, filed_path, line_items
        )
        SELECT
            p.source_type,
            p.source_id,
            p.subject,
            p.sender_email,
            p.received_at,
            -- FY year: prefer classification value, fall back to received_at period
            COALESCE(
                (SELECT fy.fy_year FROM ref.fy_periods fy
                 WHERE (NULLIF(p.raw_json->'classification'->>'fy_year',''))::int = fy.fy_year
                 LIMIT 1),
                (SELECT fy.fy_year FROM ref.fy_periods fy
                 WHERE p.received_at::date BETWEEN fy.start_date AND fy.end_date
                 LIMIT 1)
            ),
            p.file_name,
            p.file_ext,
            p.file_size_bytes,
            p.content_preview,
            -- Category lookup from ref table
            (SELECT c.category_id FROM ref.tax_categories c
             WHERE c.category_nme = (p.raw_json->'classification'->>'category')
             LIMIT 1),
            COALESCE((p.raw_json->'classification'->>'is_deductible')::boolean, FALSE),
            NULLIF(p.raw_json->'classification'->>'deductible_amount', '')::numeric,
            COALESCE((p.raw_json->'classification'->>'confidence')::numeric, 0),
            'qwen2.5:14b',
            -- Auto-classification status based on confidence
            CASE
                WHEN COALESCE((p.raw_json->'classification'->>'confidence')::numeric, 0) >= 0.75
                    THEN 'AUTO_CONFIRMED'
                ELSE 'NEEDS_REVIEW'
            END,
            p.batch_id,
            -- Enriched columns from Ollama classification
            NULLIF(p.raw_json->'classification'->>'supplier_name',    ''),
            NULLIF(p.raw_json->'classification'->>'account_reference', ''),
            NULLIF(p.raw_json->'classification'->>'supply_address',    ''),
            core.safe_to_date(p.raw_json->'classification'->>'document_date'),
            core.safe_to_date(p.raw_json->'classification'->>'billing_period_start'),
            core.safe_to_date(p.raw_json->'classification'->>'billing_period_end'),
            NULLIF(p.raw_json->'classification'->>'deductible_amount', '')::numeric,
            NULL::numeric,
            NULLIF(p.raw_json->>'filed_path', ''),
            -- line_items: granular charge detail for utility bills
            COALESCE(p.raw_json->'classification'->'line_items', '[]'::jsonb)
        FROM primary_docs p
        ON CONFLICT (source_type, source_id) DO UPDATE SET
            subject              = EXCLUDED.subject,
            sender_email         = EXCLUDED.sender_email,
            received_at          = EXCLUDED.received_at,
            file_name            = EXCLUDED.file_name,
            file_ext             = EXCLUDED.file_ext,
            file_size_bytes      = EXCLUDED.file_size_bytes,
            content_preview      = COALESCE(EXCLUDED.content_preview,   core.tax_documents.content_preview),
            fy_year              = COALESCE(EXCLUDED.fy_year,            core.tax_documents.fy_year),
            tax_category_id      = COALESCE(EXCLUDED.tax_category_id,   core.tax_documents.tax_category_id),
            is_deductible        = EXCLUDED.is_deductible,
            deductible_amount    = EXCLUDED.deductible_amount,
            confidence_score     = EXCLUDED.confidence_score,
            classification_model = EXCLUDED.classification_model,
            supplier_name        = COALESCE(EXCLUDED.supplier_name,      core.tax_documents.supplier_name),
            account_ref          = COALESCE(EXCLUDED.account_ref,        core.tax_documents.account_ref),
            supply_address       = COALESCE(EXCLUDED.supply_address,     core.tax_documents.supply_address),
            document_date        = COALESCE(EXCLUDED.document_date,      core.tax_documents.document_date),
            billing_start        = COALESCE(EXCLUDED.billing_start,      core.tax_documents.billing_start),
            billing_end          = COALESCE(EXCLUDED.billing_end,        core.tax_documents.billing_end),
            total_amount         = COALESCE(EXCLUDED.total_amount,       core.tax_documents.total_amount),
            gst_amount           = COALESCE(EXCLUDED.gst_amount,         core.tax_documents.gst_amount),
            filed_path           = COALESCE(EXCLUDED.filed_path,         core.tax_documents.filed_path),
            -- Overwrite line_items only if the new value has content (non-empty array)
            line_items           = CASE
                                       WHEN jsonb_array_length(EXCLUDED.line_items) > 0
                                       THEN EXCLUDED.line_items
                                       ELSE core.tax_documents.line_items
                                   END,
            batch_id             = EXCLUDED.batch_id,
            updated_at           = NOW()
        -- Never overwrite a record the user has already manually reviewed
        WHERE core.tax_documents.review_status NOT IN ('CONFIRMED', 'REJECTED')
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_merged FROM merged;

    -- Mark all landing rows for these source_ids as processed
    UPDATE landing.tax_documents l
    SET is_processed = TRUE
    FROM (
        SELECT DISTINCT source_type, source_id
        FROM landing.tax_documents
        WHERE is_processed = FALSE
          AND (p_batch_id IS NULL OR batch_id = p_batch_id)
    ) done
    WHERE l.source_type = done.source_type
      AND l.source_id   = done.source_id;

    RAISE NOTICE 'sp_merge_tax_documents: merged=%, skipped=%', v_merged, v_skipped;
END;
$procedure$;
