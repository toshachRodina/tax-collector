#!/usr/bin/env python3
"""
extract_folder_tax_docs.py
Tax Collector — Folder / Local Storage Scanner

Scans the staging folder for tax-relevant documents, classifies each via
Ollama, moves the file into the archive hierarchy, and lands a row in
landing.tax_documents for downstream merge into core.tax_documents.

Deploy path : /data/tax-collector/scripts/extract_folder_tax_docs.py  (inside n8n container)
              X:\automation-io\tax-collector\scripts\  (Windows mapped drive)
Staging dir : /data/tc-docs/staging/  (inside n8n container)
Archive root: /data/tc-docs/          (inside n8n container)

Environment variables required:
    TC_DB_PASSWORD   — PostgreSQL password for taxcollectorusr

Run triggered by n8n via Execute Command node (runs inside n8n Docker container).
Volume mounts: /mnt/disk2/automation-io → /data | /mnt/disk2/data/tax-collector → /data/tc-docs
"""

import hashlib
import json
import logging
import os
import re
import shutil
from datetime import datetime
from pathlib import Path
from typing import Optional

import psycopg2
import requests
from psycopg2.extras import execute_values

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
WORKFLOW_NAME  = "TC_EXTRACT_FOLDER"
SCRIPT_NAME    = "extract_folder_tax_docs.py"
SOURCE_TYPE    = "FOLDER"

STAGING_DIR    = Path(os.environ.get("TC_DOCS_ROOT", "/data/tc-docs")) / "staging"
ARCHIVE_ROOT   = Path(os.environ.get("TC_DOCS_ROOT", "/data/tc-docs"))

OLLAMA_URL     = "http://192.168.0.93:11434/api/generate"
OLLAMA_MODEL   = "qwen2.5:14b"

SUPPORTED_EXTS = {".pdf", ".png", ".jpg", ".jpeg", ".tiff", ".docx"}

DB_HOST = "192.168.0.250"
DB_PORT = 5432
DB_NAME = "taxcollectordb"
DB_USER = "taxcollectorusr"

# Minimum confidence threshold below which a file goes to the low-confidence bucket
CONFIDENCE_THRESHOLD = 0.6

# ---------------------------------------------------------------------------
# Category → archive path mapping
# ---------------------------------------------------------------------------
CATEGORY_TO_PATH = {
    "Payment Summary / Income Statement": "01-income/payslips",
    "Bank Interest":                      "01-income/bank-interest",
    "Dividends":                          "01-income/dividends",
    "Share Trade / CGT Event":            "03-investments/cgt-events",
    "Work From Home — Electricity/Gas":   "02-deductions/work-from-home/utilities",
    "Work From Home — Internet":          "02-deductions/work-from-home/internet",
    "Technology Equipment":               "02-deductions/technology",
    "Software & Subscriptions":           "02-deductions/technology",
    "Professional Development":           "02-deductions/professional-dev",
    "Income Protection Insurance":        "02-deductions/insurance",
    "ATO Notice / Assessment":            "06-government/ato-notices",
    "HECS-HELP":                          "06-government/hecs-help",
    "Superannuation":                     "04-superannuation",
    "Private Health Insurance":           "05-health",
    "Rental Income":                      "07-property",
    "Property Depreciation":              "07-property",
    "Utility Bill":                       "08-receipts-bills/utilities",
    "Motor Vehicle / Logbook":            "02-deductions/motor-vehicle",
    "Donations":                          "02-deductions/donations",
    "Tax Agent Fees":                     "02-deductions/tax-agent-fees",
    "Work-Related Assets":                "02-deductions/work-assets",
    "Other":                              "08-receipts-bills/other",
}

LOW_CONFIDENCE_PATH = "08-receipts-bills/other"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def get_db_connection() -> psycopg2.extensions.connection:
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT,
        database=DB_NAME, user=DB_USER,
        password=os.environ["TC_DB_PASSWORD"],
    )
    return conn


def start_batch(conn) -> int:
    sql = """
        INSERT INTO ctl.process_log (workflow_nme, script_nme, status, started_at)
        VALUES (%s, %s, 'STARTED', NOW())
        RETURNING batch_id;
    """
    with conn.cursor() as cur:
        cur.execute(sql, (WORKFLOW_NAME, SCRIPT_NAME))
        batch_id = cur.fetchone()[0]
    conn.commit()
    return batch_id


def complete_batch(conn, batch_id: int, status: str,
                   rows_extracted: int, rows_loaded: int,
                   rows_skipped: int, error_msg: str = None) -> None:
    sql = """
        UPDATE ctl.process_log
        SET status         = %s,
            rows_extracted = %s,
            rows_loaded    = %s,
            rows_skipped   = %s,
            error_msg      = %s,
            completed_at   = NOW()
        WHERE batch_id = %s;
    """
    with conn.cursor() as cur:
        cur.execute(sql, (status, rows_extracted, rows_loaded,
                          rows_skipped, error_msg, batch_id))
    conn.commit()


def get_current_fy_year(conn) -> int:
    """Return the fy_year integer (e.g. 2025) for the current financial year."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT end_date FROM ref.fy_periods WHERE is_current = TRUE;"
        )
        row = cur.fetchone()
    if not row:
        raise RuntimeError("No current FY found in ref.fy_periods")
    # end_date is the June 30 date; its year is the FY year (e.g. 2025-06-30 → 2025)
    return row[0].year


def check_duplicate(conn, file_hash: str) -> Optional[int]:
    """
    Return landing_id if this file_hash already exists in landing.tax_documents,
    otherwise return None.
    """
    sql = """
        SELECT landing_id
        FROM landing.tax_documents
        WHERE raw_json->>'file_hash' = %s
        LIMIT 1;
    """
    with conn.cursor() as cur:
        cur.execute(sql, (file_hash,))
        row = cur.fetchone()
    return row[0] if row else None


def fetch_few_shot_examples(conn) -> list[dict]:
    """
    Fetch up to 10 confirmed/rejected examples from core.tax_documents for
    few-shot prompting. Returns list of dicts with keys: subject, file_name,
    category_nme, is_deductible.
    """
    sql = """
        SELECT d.subject, d.file_name, c.category_nme, d.is_deductible
        FROM core.tax_documents d
        JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
        WHERE d.review_status IN ('CONFIRMED', 'REJECTED')
          AND d.tax_category_id IS NOT NULL
        ORDER BY d.updated_at DESC NULLS LAST
        LIMIT 10;
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        rows = cur.fetchall()
    return [
        {
            "subject":      row[0],
            "file_name":    row[1],
            "category_nme": row[2],
            "is_deductible": row[3],
        }
        for row in rows
    ]


def insert_landing_row(conn, row: dict, batch_id: int) -> bool:
    """
    Insert one row into landing.tax_documents.
    Returns True if the row was inserted, False if it was a conflict (DO NOTHING).
    """
    sql = """
        INSERT INTO landing.tax_documents
            (source_type, source_id, subject, file_name, file_ext,
             file_size_bytes, content_preview, raw_json, batch_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (source_type, source_id, COALESCE(file_name, ''))
        DO NOTHING;
    """
    with conn.cursor() as cur:
        cur.execute(sql, (
            row["source_type"],
            row["source_id"],
            row["subject"],
            row["file_name"],
            row["file_ext"],
            row["file_size_bytes"],
            row["content_preview"],
            json.dumps(row["raw_json"]),
            batch_id,
        ))
        inserted = cur.rowcount
    conn.commit()
    return inserted > 0


# ---------------------------------------------------------------------------
# File processing helpers
# ---------------------------------------------------------------------------

def compute_sha256(file_path: Path) -> str:
    """Return the hex SHA-256 digest of the file's raw bytes."""
    h = hashlib.sha256()
    with file_path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def extract_text(file_path: Path) -> Optional[str]:
    """
    Extract text content from a file.
    - PDF: pdfplumber
    - DOCX: python-docx
    - Images: not supported yet — returns None
    """
    ext = file_path.suffix.lower()

    if ext == ".pdf":
        try:
            import pdfplumber
            text_parts = []
            with pdfplumber.open(str(file_path)) as pdf:
                for page in pdf.pages:
                    page_text = page.extract_text()
                    if page_text:
                        text_parts.append(page_text)
            return "\n".join(text_parts) if text_parts else None
        except Exception as e:
            log.warning(f"pdfplumber failed on {file_path.name}: {e}")
            return None

    elif ext == ".docx":
        try:
            from docx import Document
            doc = Document(str(file_path))
            paragraphs = [p.text for p in doc.paragraphs if p.text.strip()]
            return "\n".join(paragraphs) if paragraphs else None
        except ImportError:
            log.warning("python-docx not installed — skipping text extraction for DOCX")
            return None
        except Exception as e:
            log.warning(f"python-docx failed on {file_path.name}: {e}")
            return None

    elif ext in {".png", ".jpg", ".jpeg", ".tiff"}:
        # Vision model not yet implemented
        return None

    return None


def build_few_shot_block(examples: list[dict]) -> str:
    """Format few-shot examples into a prompt block string."""
    lines = []
    for ex in examples:
        label = ex.get("subject") or ex.get("file_name") or "unknown"
        deductible = ex.get("is_deductible")
        lines.append(
            f'- "{label}" → {ex["category_nme"]} (is_deductible: {deductible})'
        )
    return "\n".join(lines)


def classify_with_ollama(file_name: str, text_preview: Optional[str],
                         few_shot_examples: list[dict]) -> dict:
    """
    Send the document to Ollama for classification.
    Returns a dict with keys: category, fy_year, supplier_name, is_deductible,
    confidence, total_amount, document_date.
    Falls back to category="Other", confidence=0.0 on any error.
    """
    fallback = {
        "category":      "Other",
        "fy_year":       None,
        "supplier_name": None,
        "is_deductible": False,
        "confidence":    0.0,
        "total_amount":  None,
        "document_date": None,
    }

    # Build optional few-shot block
    if len(few_shot_examples) >= 3:
        few_shot_block = (
            "Here are recent examples of correctly classified documents:\n"
            + build_few_shot_block(few_shot_examples)
            + "\n\n"
        )
    else:
        few_shot_block = ""

    preview_text = (text_preview or "")[:1000] if text_preview else "(no text extracted)"

    prompt = f"""You are a document classifier for Australian personal tax records.

{few_shot_block}Now classify this document:
File name: {file_name}
Text content (first 1000 chars):
{preview_text}

Classify into one of these categories:
- Payment Summary / Income Statement
- Bank Interest
- Dividends
- Share Trade / CGT Event
- Work From Home — Electricity/Gas
- Work From Home — Internet
- Technology Equipment
- Software & Subscriptions
- Professional Development
- Income Protection Insurance
- ATO Notice / Assessment
- HECS-HELP
- Superannuation
- Private Health Insurance
- Rental Income
- Property Depreciation
- Utility Bill
- Motor Vehicle / Logbook
- Donations
- Tax Agent Fees
- Work-Related Assets
- Other

Also determine:
- fy_year: Australian financial year (e.g. 2025 for Jul 2024–Jun 2025). Null if unclear.
- supplier_name: company or institution that issued it
- is_deductible: true/false
- confidence: 0.0 to 1.0
- total_amount: numeric dollar amount if visible, else null
- document_date: ISO date string if visible (YYYY-MM-DD), else null

Respond ONLY with valid JSON:
{{"category": "...", "fy_year": 2025, "supplier_name": "...", "is_deductible": true, "confidence": 0.85, "total_amount": null, "document_date": null}}"""

    try:
        response = requests.post(
            OLLAMA_URL,
            json={"model": OLLAMA_MODEL, "prompt": prompt, "stream": False},
            timeout=120,
        )
        response.raise_for_status()
        raw_text = response.json().get("response", "")

        # Strip markdown code fences if present
        cleaned = re.sub(r"```(?:json)?\s*", "", raw_text).strip()
        cleaned = cleaned.rstrip("`").strip()

        result = json.loads(cleaned)

        # Validate and sanitise required fields
        category = result.get("category", "Other")
        if category not in CATEGORY_TO_PATH:
            log.warning(f"Ollama returned unknown category '{category}' — using 'Other'")
            category = "Other"

        return {
            "category":      category,
            "fy_year":       result.get("fy_year"),
            "supplier_name": result.get("supplier_name"),
            "is_deductible": bool(result.get("is_deductible", False)),
            "confidence":    float(result.get("confidence", 0.0)),
            "total_amount":  result.get("total_amount"),
            "document_date": result.get("document_date"),
        }

    except json.JSONDecodeError as e:
        log.warning(f"Ollama JSON parse error for {file_name}: {e} — falling back to Other")
        return fallback
    except requests.RequestException as e:
        log.warning(f"Ollama request failed for {file_name}: {e} — falling back to Other")
        return fallback
    except Exception as e:
        log.warning(f"Unexpected Ollama error for {file_name}: {e} — falling back to Other")
        return fallback


def fy_year_to_folder(fy_year: int) -> str:
    """Convert fy_year integer to folder name string, e.g. 2025 → '2024-2025'."""
    return f"{fy_year - 1}-{fy_year}"


def build_destination(fy_year: int, category: str, confidence: float,
                      original_filename: str) -> Path:
    """
    Compute the full destination path for the file.
    Low-confidence files are routed to the other bucket regardless of category.
    """
    if confidence < CONFIDENCE_THRESHOLD:
        category_path = LOW_CONFIDENCE_PATH
    else:
        category_path = CATEGORY_TO_PATH.get(category, LOW_CONFIDENCE_PATH)

    fy_folder = fy_year_to_folder(fy_year)
    return ARCHIVE_ROOT / fy_folder / category_path / original_filename


def safe_move(src: Path, dest: Path) -> Path:
    """
    Move src to dest. If dest already exists, append a timestamp suffix before
    the extension. Creates destination directories as needed.
    Returns the final destination path.
    Raises RuntimeError if the move cannot be verified.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)

    if dest.exists():
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        stem = dest.stem
        suffix = dest.suffix
        dest = dest.parent / f"{stem}_{timestamp}{suffix}"
        log.info(f"Destination already exists — renaming to {dest.name}")

    shutil.move(str(src), str(dest))

    if not dest.exists():
        raise RuntimeError(f"Move verification failed: {dest} does not exist after move")

    return dest


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    conn     = get_db_connection()
    batch_id = start_batch(conn)
    log.info(f"Batch {batch_id} started — {WORKFLOW_NAME}")

    rows_extracted = 0
    rows_loaded    = 0
    rows_skipped   = 0
    rows_failed    = 0

    try:
        current_fy_year    = get_current_fy_year(conn)
        few_shot_examples  = fetch_few_shot_examples(conn)
        log.info(
            f"Current FY year: {current_fy_year} | "
            f"Few-shot examples loaded: {len(few_shot_examples)}"
        )

        # Collect all eligible files from staging
        all_files = [
            f for f in STAGING_DIR.iterdir()
            if f.is_file()
            and not f.name.startswith(".")
            and f.suffix.lower() in SUPPORTED_EXTS
        ]

        skipped_ext_count = sum(
            1 for f in STAGING_DIR.iterdir()
            if f.is_file()
            and not f.name.startswith(".")
            and f.suffix.lower() not in SUPPORTED_EXTS
        )
        if skipped_ext_count:
            log.info(f"Skipped {skipped_ext_count} file(s) with unsupported extensions")

        log.info(f"Found {len(all_files)} eligible file(s) in staging")
        rows_extracted = len(all_files)

        for src in all_files:
            log.info(f"Processing: {src.name}")

            # --- 1. SHA-256 dedup check ---
            try:
                file_hash = compute_sha256(src)
            except OSError as e:
                log.error(f"Cannot read {src.name} for hashing: {e} — skipping")
                rows_failed += 1
                continue

            existing_doc_id = check_duplicate(conn, file_hash)
            if existing_doc_id is not None:
                log.info(
                    f"DUPLICATE: {src.name} matches landing_id {existing_doc_id} — skipping"
                )
                rows_skipped += 1
                continue

            # --- 2. Text extraction ---
            text_content = extract_text(src)
            content_preview = text_content.replace('\x00', '')[:500] if text_content else None

            # --- 3. Ollama classification ---
            classification = classify_with_ollama(
                src.name, text_content, few_shot_examples
            )
            log.info(
                f"Classified '{src.name}' as '{classification['category']}' "
                f"(confidence={classification['confidence']:.2f}, "
                f"fy_year={classification['fy_year']})"
            )

            # --- 4. Determine review status ---
            if classification["confidence"] < CONFIDENCE_THRESHOLD:
                review_status = "NEEDS_REVIEW"
                log.info(
                    f"Low confidence ({classification['confidence']:.2f}) — "
                    f"routing to low-confidence bucket, status=NEEDS_REVIEW"
                )
            else:
                review_status = "PENDING"

            # --- 5. Determine FY year for path ---
            fy_year = classification.get("fy_year") or current_fy_year

            # --- 6. Build destination and move file ---
            dest = build_destination(
                fy_year, classification["category"],
                classification["confidence"], src.name
            )

            try:
                final_dest = safe_move(src, dest)
                log.info(f"Moved {src.name} → {final_dest}")
            except Exception as e:
                log.error(f"Move failed for {src.name}: {e} — leaving in staging")
                rows_failed += 1
                continue

            # --- 7. Land row in DB ---
            raw_json = {
                "original_path":    str(src),
                "destination_path": str(final_dest),
                "file_hash":        file_hash,
                "review_status":    review_status,
                "classification":   classification,
            }

            landing_row = {
                "source_type":     SOURCE_TYPE,
                "source_id":       str(final_dest),
                "subject":         src.name,
                "file_name":       src.name,
                "file_ext":        src.suffix.lstrip(".").lower() or None,
                "file_size_bytes": final_dest.stat().st_size,
                "content_preview": content_preview,
                "raw_json":        raw_json,
            }

            inserted = insert_landing_row(conn, landing_row, batch_id)
            if inserted:
                rows_loaded += 1
                log.info(f"Landed row for {src.name} in landing.tax_documents")
            else:
                log.info(f"Row for {src.name} already in landing (conflict — skipped)")
                rows_skipped += 1

        complete_batch(conn, batch_id, "SUCCESS",
                       rows_extracted, rows_loaded,
                       rows_skipped + rows_failed,
                       f"{rows_failed} file(s) failed to move" if rows_failed else None)
        log.info(
            f"Batch complete — SUCCESS | extracted={rows_extracted} "
            f"loaded={rows_loaded} skipped={rows_skipped} failed={rows_failed}"
        )

    except Exception as e:
        msg = f"Unexpected error: {e}"
        log.error(msg, exc_info=True)
        complete_batch(conn, batch_id, "FAILED",
                       rows_extracted, rows_loaded,
                       rows_skipped + rows_failed, msg)
        raise SystemExit(1)

    finally:
        conn.close()


if __name__ == "__main__":
    main()
