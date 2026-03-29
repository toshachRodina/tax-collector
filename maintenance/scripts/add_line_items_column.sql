-- Add line_items JSONB column to core.tax_documents
-- Run via: docker exec -i postgres psql -U n8nusr -d taxcollectordb < /mnt/disk2/...
-- Safe: additive only, no data loss

ALTER TABLE core.tax_documents
    ADD COLUMN IF NOT EXISTS line_items JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN core.tax_documents.line_items IS
    'Granular charge line items extracted from utility bills (electricity, gas, internet). '
    'Array of {description, period, quantity, unit, rate, amount}. '
    'Populated by Ollama classification via sp_merge_tax_documents.';
