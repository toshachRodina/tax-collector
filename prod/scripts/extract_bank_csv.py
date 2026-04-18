#!/usr/bin/env python3
"""
extract_bank_csv.py
Tax Collector — NAB Bank CSV Extractor

Scans the staging folder for NAB bank statement CSV files, parses each row,
applies rule-based deductibility classification, and lands rows in
landing.bank_transactions for downstream merge into core.bank_transactions.

Deploy path : /data/tax-collector/scripts/extract_bank_csv.py  (inside n8n container)
              X:\automation-io\tax-collector\scripts\  (Windows mapped drive)
Staging dir : /data/tc-docs/staging/  (inside n8n container)
Archive root: /data/tc-docs/          (inside n8n container)

Environment variables required:
    TC_DB_PASSWORD   — PostgreSQL password for taxcollectorusr
    TC_DOCS_ROOT     — (optional) override base data directory; default /data/tc-docs

Run triggered by n8n via Execute Command node (runs inside n8n Docker container).
Volume mounts: /mnt/disk2/automation-io → /data | /mnt/disk2/data/tax-collector → /data/tc-docs
"""

import csv
import hashlib
import logging
import os
import re
import shutil
from datetime import datetime, date
from pathlib import Path
from typing import Optional

import psycopg2

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
WORKFLOW_NAME  = "TC_EXTRACT_BANK_CSV"
SCRIPT_NAME    = "extract_bank_csv.py"

STAGING_DIR    = Path(os.environ.get("TC_DOCS_ROOT", "/data/tc-docs")) / "staging"
ARCHIVE_ROOT   = Path(os.environ.get("TC_DOCS_ROOT", "/data/tc-docs"))

SUPPORTED_PATTERN = re.compile(r'^NAB.*\.csv$', re.IGNORECASE)

DB_HOST = "192.168.0.250"
DB_PORT = 5432
DB_NAME = "taxcollectordb"
DB_USER = "taxcollectorusr"

# ---------------------------------------------------------------------------
# NAB category → (tax_category_nme, is_potentially_deductible, deductible_notes)
#
# PURPOSE: This mapping identifies categories that are WORTH CROSS-REFERENCING
# against core.tax_documents at merge time. It does NOT mean the transaction
# itself is deductible — the receipt/statement IS the deductible item, not the
# transaction line.
#
# Two legitimate uses:
#   1. Interest rows → must be declared as ATO income (no separate document expected)
#   2. All other flagged rows → gap indicators: check if a matching receipt/statement
#      exists in core.tax_documents. If not, surface in vw_missing_receipt_indicators.
#
# tax_category_nme is used to look up ref.tax_categories.category_id at load time.
# None means no matching tax category — insert NULL tax_category_id.
# ---------------------------------------------------------------------------
FLAGGED_NAB_CATEGORIES = {
    'Subscriptions':        ('Software & Subscriptions', True,  'Recurring subscription — check for matching receipt in documents'),
    'Electronic Shopping':  ('Technology Equipment',     None,  'Electronics purchase — check for matching receipt in documents'),
    'Health & Medical':     ('Private Health Insurance', None,  'Medical expense — check for annual statement in documents'),
    'Education':            ('Professional Development', True,  'Education expense — check for receipt or enrolment letter in documents'),
    'Business Services':    (None,                       True,  'Business service — check for invoice in documents'),
    'Tax & Accountant':     ('Tax Agent Fees',           True,  'Tax-related expense — check for invoice in documents'),
    'Interest':             ('Bank Interest',            False, 'Interest received — declare as ATO income (no receipt expected)'),
    'Donations':            ('Donations',                True,  'Charitable donation — check for receipt in documents'),
    'Transport':            ('Motor Vehicle / Logbook',  None,  'Transport — check for logbook or receipt in documents'),
}
# Backwards-compatible alias used by classify_row()
DEDUCTIBLE_NAB_CATEGORIES = FLAGGED_NAB_CATEGORIES

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Account label derivation
# ---------------------------------------------------------------------------

def account_label_from_filename(filename: str) -> str:
    """
    Derive a human-readable account label from the CSV filename.
    Examples:
        NAB_Visa_2025.csv       → 'VISA'
        NAB_Savings1_2025.csv   → 'Savings1'
        NAB_Savings2_Jan25.csv  → 'Savings2'
        NAB_Transactions.csv    → 'Unknown'
    """
    name = filename.upper()
    if 'VISA' in name:
        return 'VISA'
    m = re.search(r'SAVINGS(\d+)', name)
    if m:
        return f'Savings{m.group(1)}'
    return 'Unknown'


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


def get_fy_year_for_date(conn, txn_date: date) -> Optional[int]:
    """
    Look up the fy_year from ref.fy_periods for the given transaction date.
    Returns None if the date falls outside all known FY periods.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT fy_year
            FROM ref.fy_periods
            WHERE %s BETWEEN start_date AND end_date
            LIMIT 1;
            """,
            (txn_date,),
        )
        row = cur.fetchone()
    return row[0] if row else None


def get_tax_category_id(conn, category_nme: str) -> Optional[int]:
    """
    Look up ref.tax_categories.category_id by category_nme.
    Returns None if not found.
    """
    with conn.cursor() as cur:
        cur.execute(
            "SELECT category_id FROM ref.tax_categories WHERE category_nme = %s LIMIT 1;",
            (category_nme,),
        )
        row = cur.fetchone()
    return row[0] if row else None


def row_already_landed(conn, row_hash: str) -> bool:
    """Return True if this row_hash already exists in landing.bank_transactions."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM landing.bank_transactions WHERE row_hash = %s LIMIT 1;",
            (row_hash,),
        )
        return cur.fetchone() is not None


def insert_landing_row(conn, row: dict, batch_id: int) -> bool:
    """
    Insert one row into landing.bank_transactions.
    Returns True if inserted, False if conflicted (ON CONFLICT DO NOTHING).
    """
    sql = """
        INSERT INTO landing.bank_transactions (
            batch_id, source_file, account_number, txn_date, amount,
            transaction_type, transaction_details, balance, nab_category,
            merchant_name, processed_on, row_hash
        ) VALUES (
            %s, %s, %s, %s, %s,
            %s, %s, %s, %s,
            %s, %s, %s
        )
        ON CONFLICT (row_hash) DO NOTHING;
    """
    with conn.cursor() as cur:
        cur.execute(sql, (
            batch_id,
            row["source_file"],
            row["account_number"],
            row["txn_date"],
            row["amount"],
            row["transaction_type"],
            row["transaction_details"],
            row["balance"],
            row["nab_category"],
            row["merchant_name"],
            row["processed_on"],
            row["row_hash"],
        ))
        inserted = cur.rowcount
    conn.commit()
    return inserted > 0


# ---------------------------------------------------------------------------
# CSV parsing helpers
# ---------------------------------------------------------------------------

def compute_row_hash(account_number: Optional[str], txn_date: date,
                     amount: Optional[float], transaction_details: Optional[str]) -> str:
    """
    SHA-256 of: account_number + txn_date.isoformat() + str(amount) + transaction_details
    All parts coerced to empty string if None.
    """
    raw = (
        (account_number or "")
        + (txn_date.isoformat() if txn_date else "")
        + (str(amount) if amount is not None else "")
        + (transaction_details or "")
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def parse_date(raw: str) -> Optional[date]:
    """Parse NAB date format: '06 Apr 26' → date(2026, 4, 6).
    NAB inconsistently uses 'Sept' instead of 'Sep' — normalise before parsing.
    """
    raw = raw.strip()
    if not raw:
        return None
    raw = re.sub(r'\bSept\b', 'Sep', raw, flags=re.IGNORECASE)
    try:
        return datetime.strptime(raw, "%d %b %y").date()
    except ValueError:
        log.warning(f"Cannot parse date: '{raw}'")
        return None


def parse_amount(raw: str) -> Optional[float]:
    """Parse amount string, stripping commas. Returns None for blank."""
    raw = raw.strip()
    if not raw:
        return None
    try:
        return float(raw.replace(",", ""))
    except ValueError:
        log.warning(f"Cannot parse amount: '{raw}'")
        return None


def classify_row(nab_category: Optional[str]) -> tuple:
    """
    Rule-based deductibility classification from NAB category.
    Returns (tax_category_nme_or_none, is_potentially_deductible, deductible_notes_or_none).
    """
    if not nab_category:
        return (None, False, None)
    rule = DEDUCTIBLE_NAB_CATEGORIES.get(nab_category.strip())
    if rule:
        cat_nme, deductible, notes = rule
        # None deductible flag means "possibly" — we flag it for review
        is_deductible = bool(deductible) if deductible is not None else True
        return (cat_nme, is_deductible, notes)
    return (None, False, None)


def parse_csv_file(file_path: Path) -> list[dict]:
    """
    Parse a NAB bank statement CSV file.

    NAB CSV column layout (0-indexed):
        0  Date
        1  Amount
        2  Account Number
        3  (blank / internal NAB column — skip)
        4  Transaction Type
        5  Transaction Details
        6  Balance
        7  Category
        8  Merchant Name
        9  Processed On

    Returns a list of parsed row dicts. Skips blank/header rows silently.
    """
    rows = []
    account_label = account_label_from_filename(file_path.name)
    source_file = file_path.name

    with file_path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        for line_num, raw_row in enumerate(reader, start=1):
            # Skip rows that are entirely empty
            if not any(cell.strip() for cell in raw_row):
                continue

            # NAB CSVs may have a header row starting with 'Date' — skip it
            if raw_row[0].strip().lower() == 'date':
                continue

            # Ensure we have enough columns
            if len(raw_row) < 9:
                log.warning(
                    f"{source_file} line {line_num}: only {len(raw_row)} columns — skipping"
                )
                continue

            txn_date = parse_date(raw_row[0])
            amount = parse_amount(raw_row[1])
            account_number = raw_row[2].strip() or None
            # raw_row[3] is blank — skip
            transaction_type = raw_row[4].strip() or None
            transaction_details = raw_row[5].strip() or None
            balance = parse_amount(raw_row[6])
            nab_category = raw_row[7].strip() or None
            merchant_name = raw_row[8].strip() or None
            processed_on_raw = raw_row[9].strip() if len(raw_row) > 9 else ""
            processed_on = parse_date(processed_on_raw) if processed_on_raw else None

            if txn_date is None:
                log.warning(
                    f"{source_file} line {line_num}: invalid date '{raw_row[0]}' — skipping"
                )
                continue

            row_hash = compute_row_hash(account_number, txn_date, amount, transaction_details)

            rows.append({
                "source_file":          source_file,
                "account_label":        account_label,
                "account_number":       account_number,
                "txn_date":             txn_date,
                "amount":               amount,
                "transaction_type":     transaction_type,
                "transaction_details":  transaction_details,
                "balance":              balance,
                "nab_category":         nab_category,
                "merchant_name":        merchant_name,
                "processed_on":         processed_on,
                "row_hash":             row_hash,
            })

    return rows


def move_to_archive(src: Path) -> Path:
    """
    Move processed CSV to ARCHIVE_ROOT/processed-csv/<filename>.
    If a file with the same name already exists in the archive, append a
    timestamp suffix before the extension.
    Returns the final destination path.
    """
    archive_dir = ARCHIVE_ROOT / "processed-csv"
    archive_dir.mkdir(parents=True, exist_ok=True)

    dest = archive_dir / src.name
    if dest.exists():
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        dest = archive_dir / f"{src.stem}_{ts}{src.suffix}"

    shutil.move(str(src), str(dest))

    if not dest.exists():
        raise RuntimeError(f"Archive move verification failed: {dest} does not exist after move")

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
        # Collect all NAB CSV files in staging
        all_files = [
            f for f in STAGING_DIR.iterdir()
            if f.is_file()
            and not f.name.startswith(".")
            and SUPPORTED_PATTERN.match(f.name)
        ]

        skipped_ext_count = sum(
            1 for f in STAGING_DIR.iterdir()
            if f.is_file()
            and not f.name.startswith(".")
            and not SUPPORTED_PATTERN.match(f.name)
        )
        if skipped_ext_count:
            log.info(f"Skipped {skipped_ext_count} file(s) not matching NAB CSV pattern")

        log.info(f"Found {len(all_files)} NAB CSV file(s) in staging")

        for src in all_files:
            log.info(f"Processing: {src.name}")

            # --- 1. Parse CSV ---
            try:
                parsed_rows = parse_csv_file(src)
            except Exception as e:
                log.error(f"Failed to parse {src.name}: {e} — skipping file")
                rows_failed += 1
                continue

            log.info(f"  Parsed {len(parsed_rows)} row(s) from {src.name}")
            rows_extracted += len(parsed_rows)

            # --- 2. Process each row ---
            file_loaded  = 0
            file_skipped = 0

            for row in parsed_rows:
                # Dedup check
                if row_already_landed(conn, row["row_hash"]):
                    log.debug(f"  SKIP (already landed): {row['row_hash'][:12]}… {row['txn_date']} {row['amount']}")
                    rows_skipped += 1
                    file_skipped += 1
                    continue

                # FY year lookup
                fy_year = get_fy_year_for_date(conn, row["txn_date"]) if row["txn_date"] else None
                if fy_year is None:
                    log.warning(
                        f"  No FY period found for {row['txn_date']} — "
                        f"row will land with NULL fy_year"
                    )

                # Rule-based deductibility classification
                tax_cat_nme, is_deductible, notes = classify_row(row["nab_category"])

                # Resolve tax_category_id from name
                tax_category_id = None
                if tax_cat_nme:
                    tax_category_id = get_tax_category_id(conn, tax_cat_nme)
                    if tax_category_id is None:
                        log.warning(
                            f"  tax_category_nme '{tax_cat_nme}' not found in ref.tax_categories — "
                            f"tax_category_id will be NULL"
                        )

                # Build landing row — fy_year, tax_category_id, deductibility
                # are NOT stored in landing; they're resolved at LOAD_CORE time.
                # We store only the raw fields in landing.
                landing_row = {
                    "source_file":          row["source_file"],
                    "account_number":       row["account_number"],
                    "txn_date":             row["txn_date"],
                    "amount":               row["amount"],
                    "transaction_type":     row["transaction_type"],
                    "transaction_details":  row["transaction_details"],
                    "balance":              row["balance"],
                    "nab_category":         row["nab_category"],
                    "merchant_name":        row["merchant_name"],
                    "processed_on":         row["processed_on"],
                    "row_hash":             row["row_hash"],
                }

                inserted = insert_landing_row(conn, landing_row, batch_id)
                if inserted:
                    rows_loaded  += 1
                    file_loaded  += 1
                    log.debug(
                        f"  Landed: {row['txn_date']} {row['amount']:>10} "
                        f"{row['nab_category'] or '—':<25} "
                        f"deductible={is_deductible}"
                    )
                else:
                    rows_skipped += 1
                    file_skipped += 1

            log.info(
                f"  {src.name}: loaded={file_loaded} skipped={file_skipped}"
            )

            # --- 3. Archive the CSV ---
            try:
                dest = move_to_archive(src)
                log.info(f"  Archived {src.name} → {dest}")
            except Exception as e:
                log.error(f"  Archive move failed for {src.name}: {e} — file left in staging")
                rows_failed += 1

        complete_batch(conn, batch_id, "SUCCESS",
                       rows_extracted, rows_loaded,
                       rows_skipped + rows_failed,
                       f"{rows_failed} file(s) failed" if rows_failed else None)
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
