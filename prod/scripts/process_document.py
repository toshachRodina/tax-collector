#!/usr/bin/env python3
# process_document.py — Shared document processor for Tax Collector
#
# Requires: pdfplumber — installed in hub-n8n via homelab-hub/n8n-build/Dockerfile
#
# Usage:
#   python3 process_document.py --file <path> [--meta <json-string>] [--source-type GMAIL|FOLDER|MANUAL]

import argparse
import json
import logging
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DB_CONFIG = {
    "host": "192.168.0.250",
    "port": 5432,
    "database": "taxcollectordb",
    "user": "taxcollectorusr",
}

OLLAMA_URL = "http://192.168.0.93:11434/api/generate"
OLLAMA_MODEL = "qwen2.5:14b"
OLLAMA_TIMEOUT = 120

TC_DOCS_ROOT = os.environ.get("TC_DOCS_ROOT", "/data/tax-collector/docs")

CATEGORY_DIR_MAP = {
    "Payment Summary / Group Certificate": "income/payslips",
    "Bank Interest Statement":             "income/interest",
    "Dividend Statement":                  "income/dividends",
    "Share Sale / CGT Event":              "investments",
    "Work From Home — Internet":           "deductions/work-related",
    "Work From Home — Electricity/Gas":    "deductions/work-related",
    "Work From Home — Insurance":          "deductions/insurance",
    "Technology Equipment":                "deductions/work-related",
    "Software & Subscriptions":            "deductions/work-related",
    "Professional Development":            "deductions/work-related",
    "Professional Memberships":            "deductions/work-related",
    "Income Protection Insurance":         "deductions/insurance",
    "Rental Income Statement":             "investments",
    "Property Depreciation Schedule":      "investments",
    "ATO Notice / Assessment":             "government",
    "HECS/HELP Statement":                 "government",
    "Superannuation Statement":            "super",
    "Super Contribution Notice":           "super",
    "Private Health Insurance Statement":  "health",
    "Invoice / Receipt — Other":           "receipts-and-bills/other",
}

DEFAULT_CATEGORY = "Invoice / Receipt — Other"

OLLAMA_PROMPT = """\
You are an Australian tax document classifier. Analyse the following document text and return a JSON object.

Document text:
{text}

Return ONLY a JSON object with these exact fields:
{{"is_tax_relevant": <see rules below>, "category": "<one of the exact category names listed below>", "fy_year": <integer end year e.g. 2025 for FY2025 July2024-June2025>, "is_deductible": <true|false>, "deductible_amount": <numeric total amount payable if clearly stated else null>, "confidence": <float 0.0-1.0>, "document_type": "<brief type>", "document_date": "<YYYY-MM-DD if found else null>", "summary": "<one sentence>", "billing_period_start": "<YYYY-MM-DD if a billing/statement period start date is found else null>", "billing_period_end": "<YYYY-MM-DD if a billing/statement period end date is found else null>", "supplier_name": "<name of the company issuing the document if found else null>", "supply_address": "<service/supply address if found else null>", "account_reference": "<account number, NMI, policy number, or other reference if found else null>", "line_items": <see rules below>}}

is_tax_relevant rules — set TRUE only if the document is one of:
- Utility bill (electricity, gas, internet, phone) for a property where the person lives or works
- Invoice or receipt for work-related equipment, software, subscriptions, or professional services
- Income document: payslip, payment summary, dividend statement, bank interest, share sale
- Insurance: income protection, health insurance, home/contents if work-from-home
- Superannuation: statements, contribution notices
- Government: ATO notices, HECS/HELP, tax assessments
- Rental property: income, expenses, depreciation schedules
- Professional development: courses, memberships, conferences directly related to current employment

Set FALSE (discard) for ALL of the following — even if they have a dollar amount:
- Food, restaurants, cafes, meal delivery (Uber Eats, DoorDash, Menulog, etc.)
- Groceries or supermarket receipts
- Entertainment: streaming services (Netflix, Disney+, Spotify unless business use), event tickets, cinema
- Personal retail: clothing, shoes, furniture, homewares (unless clearly work uniform or home-office equipment)
- Travel and accommodation for personal holidays
- Gym, fitness, personal health and beauty
- Gifts, flowers, cards
- Donations (unless to a registered DGR charity — those ARE tax relevant)
- Marketing emails or promotional PDFs with no invoice or billing information
- Order confirmations that are not tax invoices (no ABN, no GST breakdown)
- Gaming, hobbies, sports

Valid categories (use exact text):
Payment Summary / Group Certificate
Bank Interest Statement
Dividend Statement
Share Sale / CGT Event
Work From Home — Internet
Work From Home — Electricity/Gas
Work From Home — Insurance
Technology Equipment
Software & Subscriptions
Professional Development
Professional Memberships
Income Protection Insurance
Rental Income Statement
Property Depreciation Schedule
ATO Notice / Assessment
HECS/HELP Statement
Superannuation Statement
Super Contribution Notice
Private Health Insurance Statement
Invoice / Receipt — Other

line_items rules — for electricity, gas, and internet/phone bills ONLY:
Extract every charge line as an array of objects. Each object must have:
  "description": "<charge name e.g. Peak Usage, Off-Peak Usage, Solar Feed-In, Daily Supply Charge, Gas Usage, Internet Plan>",
  "period": "<billing period this line covers if stated, e.g. '01 Jan 2025 - 31 Jan 2025', else null>",
  "quantity": <numeric amount of units consumed/supplied, e.g. 312.5, else null>,
  "unit": "<unit of measure: kWh, MJ, days, months, or null>",
  "rate": <numeric rate per unit in dollars, e.g. 0.2856, else null>,
  "amount": <numeric dollar amount for this line — positive for charges, negative for credits like solar feed-in, else null>

Example line_items for an electricity bill:
[
  {{"description": "Peak Usage", "period": null, "quantity": 180.2, "unit": "kWh", "rate": 0.3524, "amount": 63.51}},
  {{"description": "Off-Peak Usage", "period": null, "quantity": 132.1, "unit": "kWh", "rate": 0.1812, "amount": 23.94}},
  {{"description": "Solar Feed-In Credit", "period": null, "quantity": 95.3, "unit": "kWh", "rate": 0.05, "amount": -4.77}},
  {{"description": "Daily Supply Charge", "period": null, "quantity": 31, "unit": "days", "rate": 0.9482, "amount": 29.39}}
]

For all other document types (invoices, payslips, statements, etc.), set line_items to an empty array [].
If a utility bill has no itemised line detail visible in the text, set line_items to [].

Australian tax year: July 1 to June 30. FY2025 = July 2024 to June 2025.
If uncertain whether a document is tax-relevant, set is_tax_relevant false — it is better to discard a borderline document than to include irrelevant ones.
Use "Invoice / Receipt — Other" only for documents that are clearly tax-relevant but do not fit a more specific category.
"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Tax Collector document processor")
    parser.add_argument("--file", required=True, help="Absolute path to the PDF file")
    parser.add_argument("--meta", default=None, help="JSON string with email metadata (GMAIL source)")
    parser.add_argument("--meta-encoded", default=None, dest="meta_encoded",
                        help="URL-encoded JSON metadata (alternative to --meta, shell-safe)")
    parser.add_argument("--base64-data", default=None, dest="base64_data",
                        help="Base64url PDF data to decode and write to --file before processing")
    parser.add_argument("--source-type", default="FOLDER", choices=["GMAIL", "FOLDER", "MANUAL"])
    return parser.parse_args()


def connect_db():
    password = os.environ.get("TC_DB_PASSWORD")
    if not password:
        raise RuntimeError("TC_DB_PASSWORD environment variable is required")
    return psycopg2.connect(**DB_CONFIG, password=password)


def start_batch(conn):
    sql = """
        INSERT INTO ctl.process_log (workflow_nme, script_nme, status, started_at)
        VALUES ('TC_PROCESS_DOCUMENT', 'process_document.py', 'STARTED', NOW())
        RETURNING batch_id;
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        batch_id = cur.fetchone()[0]
    conn.commit()
    log.info("Batch started: batch_id=%s", batch_id)
    return batch_id


def update_batch(conn, batch_id, status, rows_extracted=0, rows_loaded=0, error_msg=None):
    if status == "SUCCESS":
        sql = """
            UPDATE ctl.process_log
            SET status = %s, rows_extracted = %s, rows_loaded = %s, completed_at = NOW()
            WHERE batch_id = %s;
        """
        with conn.cursor() as cur:
            cur.execute(sql, (status, rows_extracted, rows_loaded, batch_id))
    else:
        sql = """
            UPDATE ctl.process_log
            SET status = %s, error_msg = %s, completed_at = NOW()
            WHERE batch_id = %s;
        """
        with conn.cursor() as cur:
            cur.execute(sql, (status, error_msg, batch_id))
    conn.commit()


def extract_text(file_path):
    try:
        import pdfplumber
        with pdfplumber.open(file_path) as pdf:
            pages_text = []
            for page in pdf.pages:
                t = page.extract_text()
                if t:
                    pages_text.append(t)
            raw = "\n".join(pages_text)
            return raw.replace("\x00", "")
    except ImportError:
        log.error("pdfplumber not installed — cannot extract text")
        return ""
    except Exception as exc:
        log.warning("Text extraction failed (image-only PDF?): %s", exc)
        return ""


def classify_with_ollama(text):
    if not text:
        log.info("No text extracted — using default category with low confidence")
        return {
            "category": DEFAULT_CATEGORY,
            "fy_year": None,
            "is_deductible": False,
            "deductible_amount": None,
            "confidence": 0.1,
            "document_type": "Unknown",
            "document_date": None,
            "summary": "No text could be extracted from this document.",
        }

    truncated = text[:6000]
    prompt = OLLAMA_PROMPT.format(text=truncated)

    payload = {
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
        "format": "json",
    }

    try:
        resp = requests.post(OLLAMA_URL, json=payload, timeout=OLLAMA_TIMEOUT)
        resp.raise_for_status()
        raw_response = resp.json().get("response", "{}")
        classification = json.loads(raw_response)
        log.info("Ollama classification: category=%s confidence=%s",
                 classification.get("category"), classification.get("confidence"))
        return classification
    except requests.exceptions.Timeout:
        log.warning("Ollama request timed out — using default category")
    except Exception as exc:
        log.warning("Ollama classification failed: %s — using default category", exc)

    return {
        "category": DEFAULT_CATEGORY,
        "fy_year": None,
        "is_deductible": False,
        "deductible_amount": None,
        "confidence": 0.1,
        "document_type": "Unknown",
        "document_date": None,
        "summary": "Classification failed; defaulting to generic receipt.",
    }


def determine_fy_year(classification):
    today = datetime.now(timezone.utc)
    raw = classification.get("fy_year")
    try:
        year = int(raw)
        if 2020 <= year <= 2035:
            return year
    except (TypeError, ValueError):
        pass
    return today.year + 1 if today.month >= 7 else today.year


def build_dest_path(file_path, fy_year, category, supplier_name=None):
    subdir = CATEGORY_DIR_MAP.get(category, "receipts-and-bills/other")
    fy_start = fy_year - 1
    fy_dir = f"{fy_start}-{fy_year}"
    dest_dir = Path(TC_DOCS_ROOT) / fy_dir / subdir
    dest_dir.mkdir(parents=True, exist_ok=True)

    original = Path(file_path).name
    if supplier_name:
        # Sanitise supplier name: strip chars that are problematic in filenames
        safe_supplier = re.sub(r'[\\/:*?"<>|]', '', supplier_name).strip()
        if safe_supplier:
            original = f"{safe_supplier} - {original}"

    # shutil.move will overwrite if destination exists — safe because
    # same Gmail source_id always produces the same destination path.
    return dest_dir / original


def get_category_id(conn, category_nme):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT category_id FROM ref.tax_categories WHERE category_nme = %s",
            (category_nme,)
        )
        row = cur.fetchone()
    return row[0] if row else None


def land_document(conn, *, source_type, source_id, meta, file_path_original,
                  file_path_final, text, classification, batch_id):
    today = datetime.now(timezone.utc)

    file_name = (meta.get("file_name") if meta else None) or os.path.basename(file_path_original)
    raw_ext = (meta.get("file_ext") if meta else None) or Path(file_path_original).suffix.lstrip(".")
    file_ext = raw_ext.lower() if raw_ext else None

    if meta and meta.get("file_size_bytes"):
        file_size_bytes = meta["file_size_bytes"]
    else:
        try:
            file_size_bytes = os.path.getsize(file_path_final)
        except OSError:
            file_size_bytes = None

    if meta and meta.get("received_at"):
        received_at = meta["received_at"]
    else:
        try:
            mtime = os.path.getmtime(file_path_original)
            received_at = datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
        except OSError:
            received_at = today.isoformat()

    subject = meta.get("subject") if meta else None
    sender_email = meta.get("sender_email") if meta else None
    content_preview = text[:500] if text else None

    raw_json_dict = {
        "filed_path": str(file_path_final),
        "classification": classification,
        "full_text": text if text else "",
        "text_length": len(text) if text else 0,
        "processed_at": today.isoformat(),
    }
    if meta:
        raw_json_dict.update(meta)

    raw_json = json.dumps(raw_json_dict).replace('\x00', '')

    # Strip NUL bytes from string fields — some PDFs/emails embed binary that
    # survives into metadata and causes PostgreSQL "string literal cannot contain
    # NUL (0x00) characters" errors.
    def _clean(v):
        return v.replace('\x00', '') if isinstance(v, str) else v

    subject        = _clean(subject)
    sender_email   = _clean(sender_email)
    content_preview = _clean(content_preview) if content_preview else content_preview

    sql = """
        INSERT INTO landing.tax_documents
            (source_type, source_id, subject, sender_email, received_at,
             file_name, file_ext, file_size_bytes, content_preview, raw_json, batch_id)
        VALUES
            (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (source_type, source_id, COALESCE(file_name, ''))
        DO NOTHING
        RETURNING landing_id;
    """

    with conn.cursor() as cur:
        cur.execute(sql, (
            source_type,
            source_id,
            subject,
            sender_email,
            received_at,
            file_name,
            file_ext,
            file_size_bytes,
            content_preview,
            raw_json,
            batch_id,
        ))
        row = cur.fetchone()
    conn.commit()

    landing_id = row[0] if row else None
    log.info("Landing insert: landing_id=%s (None = conflict/skipped)", landing_id)
    return landing_id


def call_sp_merge(conn, batch_id):
    with conn.cursor() as cur:
        cur.execute("CALL core.sp_merge_tax_documents(%s);", (batch_id,))
    conn.commit()
    log.info("sp_merge_tax_documents completed for batch_id=%s", batch_id)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    file_path_original = args.file

    if args.base64_data:
        import base64 as _b64
        try:
            pdf_bytes = _b64.urlsafe_b64decode(args.base64_data + '==')
            os.makedirs(os.path.dirname(file_path_original) or '/data/tax-collector/staging', exist_ok=True)
            with open(file_path_original, 'wb') as f:
                f.write(pdf_bytes)
            log.info("Wrote %d bytes to %s", len(pdf_bytes), file_path_original)
        except Exception as exc:
            log.error("Failed to decode/write base64 data: %s", exc)
            sys.exit(1)

    if not os.path.isfile(file_path_original):
        log.error("File not found: %s", file_path_original)
        sys.exit(1)

    meta = None
    if args.meta_encoded:
        try:
            from urllib.parse import unquote
            meta = json.loads(unquote(args.meta_encoded))
        except Exception as exc:
            log.error("Invalid --meta-encoded: %s", exc)
            sys.exit(1)
    elif args.meta:
        try:
            meta = json.loads(args.meta)
        except json.JSONDecodeError as exc:
            log.error("Invalid --meta JSON: %s", exc)
            sys.exit(1)

    source_type = args.source_type

    # Determine source_id
    if source_type == "GMAIL" and meta and meta.get("source_id"):
        source_id = meta["source_id"]
    else:
        source_id = file_path_original

    log.info("Processing: file=%s source_type=%s source_id=%s", file_path_original, source_type, source_id)

    conn = connect_db()
    batch_id = start_batch(conn)

    try:
        # Step 3: Extract text
        log.info("Extracting text from PDF")
        text = extract_text(file_path_original)
        log.info("Extracted %d characters", len(text))

        # Step 4: content preview
        content_preview = text[:500]

        # Step 5: Classify
        classification = classify_with_ollama(text)
        category = classification.get("category", DEFAULT_CATEGORY)
        if category not in CATEGORY_DIR_MAP:
            log.warning("Unknown category '%s' — falling back to default", category)
            category = DEFAULT_CATEGORY
            classification["category"] = category

        # Step 5b: Log tax-relevance assessment but always proceed — land everything.
        # Human review in core (review_status) is the gate, not this script.
        # AUTO_REJECTED records in core give the user visibility to correct LLM mistakes.
        is_tax_relevant = bool(classification.get("is_tax_relevant", True))
        log.info(
            "is_tax_relevant=%s confidence=%.2f category=%s — landing regardless",
            is_tax_relevant,
            classification.get("confidence", 0.0),
            classification.get("category", ""),
        )

        # Step 6: FY year
        fy_year = determine_fy_year(classification)
        log.info("FY year: %d, category: %s", fy_year, category)

        # Step 7-8: Move file — prefixed with supplier name for easy identification
        dest_path = build_dest_path(
            file_path_original, fy_year, category,
            supplier_name=classification.get("supplier_name"),
        )
        shutil.move(file_path_original, dest_path)
        log.info("Moved file to: %s", dest_path)

        # Step 9: Get category_id (informational — not required for landing insert)
        category_id = get_category_id(conn, category)
        log.info("category_id=%s", category_id)

        # Step 10: Land document
        landing_id = land_document(
            conn,
            source_type=source_type,
            source_id=source_id,
            meta=meta,
            file_path_original=file_path_original,
            file_path_final=dest_path,
            text=text,
            classification=classification,
            batch_id=batch_id,
        )

        # Step 11: Update batch SUCCESS
        # Note: merge to core.tax_documents is handled by the separate
        # TC_LOAD_CORE_TAX_DOCS n8n workflow — not called here.
        rows_loaded = 1 if landing_id else 0
        update_batch(conn, batch_id, "SUCCESS", rows_extracted=1, rows_loaded=rows_loaded)
        log.info("Done. batch_id=%s rows_loaded=%d", batch_id, rows_loaded)

    except Exception as exc:
        log.exception("Unhandled error: %s", exc)
        try:
            update_batch(conn, batch_id, "FAILED", error_msg=str(exc))
        except Exception as inner:
            log.error("Failed to update process_log to FAILED: %s", inner)
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
