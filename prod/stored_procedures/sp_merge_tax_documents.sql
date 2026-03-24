-- =============================================================================
-- sp_merge_tax_documents.sql
-- Tax Collector — Merge landing.tax_documents → core.tax_documents
--
-- Idempotent UPSERT. Safe to re-run.
-- Processes all landing rows where is_processed = FALSE.
-- Groups multi-attachment emails by (source_type, source_id) and promotes the
-- largest PDF (by file_size_bytes) as the primary core record.
-- All landing rows for the same source_id are marked is_processed = TRUE after merge.
--
-- Called by: n8n workflow TC_EXTRACT_GMAIL after extract script succeeds.
-- Run as: taxcollectorusr
-- =============================================================================

CREATE OR REPLACE PROCEDURE core.sp_merge_tax_documents(
    p_batch_id  INTEGER DEFAULT NULL   -- NULL = process all unprocessed rows
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_merged   INTEGER := 0;
    v_skipped  INTEGER := 0;
BEGIN

    -- -------------------------------------------------------------------------
    -- Step 1: For each unique (source_type, source_id) in unprocessed landing,
    --         pick the row with the largest file_size_bytes as the primary doc.
    --         If multiple rows have equal size, pick the one with the
    --         alphabetically first file_name.
    --
    -- NOTE: core.tax_documents UNIQUE (source_type, source_id) means one row
    --       per Gmail message. Multi-attachment emails are represented by their
    --       largest PDF. This is a known MVP limitation — revisit if per-
    --       attachment core rows are required.
    -- -------------------------------------------------------------------------
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
            source_type,
            source_id,
            subject,
            sender_email,
            received_at,
            fy_year,
            file_name,
            file_ext,
            file_size_bytes,
            content_preview,
            review_status,
            batch_id
        )
        SELECT
            p.source_type,
            p.source_id,
            p.subject,
            p.sender_email,
            p.received_at,
            -- Resolve FY year: find which FY period the received_at falls in
            (
                SELECT fy.fy_year
                FROM ref.fy_periods fy
                WHERE p.received_at::date BETWEEN fy.start_date AND fy.end_date
                LIMIT 1
            ),
            p.file_name,
            p.file_ext,
            p.file_size_bytes,
            p.content_preview,
            'PENDING',
            p.batch_id
        FROM primary_docs p
        ON CONFLICT (source_type, source_id) DO UPDATE SET
            -- Update mutable fields if a newer landing row supersedes the existing core row
            subject         = EXCLUDED.subject,
            sender_email    = EXCLUDED.sender_email,
            received_at     = EXCLUDED.received_at,
            file_name       = EXCLUDED.file_name,
            file_ext        = EXCLUDED.file_ext,
            file_size_bytes = EXCLUDED.file_size_bytes,
            content_preview = COALESCE(EXCLUDED.content_preview,
                                       core.tax_documents.content_preview),
            batch_id        = EXCLUDED.batch_id,
            updated_at      = NOW()
        -- Do not overwrite classification fields set by classify step
        WHERE core.tax_documents.review_status = 'PENDING'
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_merged FROM merged;

    -- -------------------------------------------------------------------------
    -- Step 2: Mark ALL landing rows for processed source_ids as done
    --         (including secondary attachments that were not promoted to core)
    -- -------------------------------------------------------------------------
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
$$;

COMMENT ON PROCEDURE core.sp_merge_tax_documents IS
    'Idempotent merge from landing.tax_documents into core.tax_documents. '
    'Groups by (source_type, source_id); promotes largest PDF per email. '
    'Marks all processed landing rows is_processed = TRUE. '
    'Pass p_batch_id to restrict to a specific batch, or NULL for all unprocessed.';
