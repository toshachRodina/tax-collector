#!/usr/bin/env python3
"""
extract_gmail_tax_docs.py
Tax Collector — Gmail Scanner

Extracts tax-relevant PDF attachment metadata from Gmail into landing.tax_documents.
No attachment content is downloaded — metadata only.

Deploy path : ~/tax-collector/scripts/extract_gmail_tax_docs.py
Config path : ~/tax-collector/config/  (credentials.json, token.json)

Environment variables required:
    TC_DB_PASSWORD   — PostgreSQL password for taxcollectorusr

Run one-time setup first:
    python3 ~/tax-collector/scripts/setup_gmail_auth.py
"""

import os
import json
import logging
from datetime import date, timedelta, datetime, timezone
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
WORKFLOW_NAME  = "TC_EXTRACT_GMAIL"
SCRIPT_NAME    = "extract_gmail_tax_docs.py"
SOURCE_TYPE    = "GMAIL"
SCOPES         = ["https://www.googleapis.com/auth/gmail.readonly"]
PAGE_SIZE      = 500   # Gmail API max per page

CONFIG_DIR     = Path.home() / "tax-collector" / "config"
TOKEN_PATH     = CONFIG_DIR / "token.json"
CREDENTIALS_PATH = CONFIG_DIR / "credentials.json"

DB_HOST = "192.168.0.250"
DB_PORT = 5432
DB_NAME = "taxcollectordb"
DB_USER = "taxcollectorusr"

TAX_KEYWORDS = [
    "invoice", "statement", "receipt", "tax", "ATO", "deduction",
    "interest", "dividend", "insurance", "payslip", "group certificate",
    "HECS", "superannuation", "depreciation",
]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def get_db_connection(encryption_key: str):
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT,
        database=DB_NAME, user=DB_USER,
        password=os.environ["TC_DB_PASSWORD"],
    )
    with conn.cursor() as cur:
        cur.execute("SET app.encryption_key TO %s", [encryption_key])
    conn.commit()
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


def get_current_fy(conn) -> tuple[date, date]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT start_date, end_date FROM ref.fy_periods WHERE is_current = TRUE;"
        )
        row = cur.fetchone()
    if not row:
        raise RuntimeError("No current FY found in ref.fy_periods")
    return row[0], row[1]


def get_watermark(conn) -> int | None:
    """Returns the last processed Gmail internalDate (epoch ms), or None on first run."""
    sql = """
        SELECT pgp_sym_decrypt(var_val, current_setting('app.encryption_key'))
        FROM ctl.ctrl_vars
        WHERE package_nme = 'TC_EXTRACT_GMAIL'
          AND var_nme     = 'LAST_INTERNAL_DATE_MS';
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
    return int(row[0]) if row else None


def update_watermark(conn, new_internal_date_ms: int) -> None:
    sql = """
        INSERT INTO ctl.ctrl_vars (package_nme, var_nme, var_val, description)
        VALUES (
            'TC_EXTRACT_GMAIL',
            'LAST_INTERNAL_DATE_MS',
            pgp_sym_encrypt(%s::text, current_setting('app.encryption_key')),
            'Watermark: max Gmail internalDate (epoch ms) from last successful run'
        )
        ON CONFLICT (package_nme, var_nme) DO UPDATE SET
            var_val    = pgp_sym_encrypt(EXCLUDED.var_val::text,
                                         current_setting('app.encryption_key')),
            updated_at = NOW();
    """
    val = str(new_internal_date_ms)
    with conn.cursor() as cur:
        cur.execute(sql, (val,))
    conn.commit()


def insert_landing_rows(conn, rows: list[dict], batch_id: int) -> int:
    if not rows:
        return 0
    sql = """
        INSERT INTO landing.tax_documents
            (source_type, source_id, subject, sender_email, received_at,
             file_name, file_ext, file_size_bytes, raw_json, batch_id)
        VALUES %s
        ON CONFLICT (source_type, source_id, COALESCE(file_name, ''))
        DO NOTHING;
    """
    values = [
        (
            r["source_type"], r["source_id"], r["subject"], r["sender_email"],
            r["received_at"], r["file_name"], r["file_ext"],
            r["file_size_bytes"], json.dumps(r["raw_json"]), batch_id,
        )
        for r in rows
    ]
    with conn.cursor() as cur:
        execute_values(cur, sql, values)
        inserted = cur.rowcount
    conn.commit()
    # rowcount after execute_values is total attempted — recount net-new via query
    return max(inserted, 0)


# ---------------------------------------------------------------------------
# Gmail
# ---------------------------------------------------------------------------

def get_gmail_service():
    """Load credentials from token.json and auto-refresh if expired."""
    if not TOKEN_PATH.exists():
        raise FileNotFoundError(
            f"Gmail token not found at {TOKEN_PATH}. "
            f"Run setup_gmail_auth.py first."
        )
    creds = Credentials.from_authorized_user_file(str(TOKEN_PATH), SCOPES)
    if creds.expired and creds.refresh_token:
        log.info("Access token expired — refreshing...")
        creds.refresh(Request())
        TOKEN_PATH.write_text(creds.to_json())
        log.info("Token refreshed and saved.")
    return build("gmail", "v1", credentials=creds)


def build_gmail_query(after_date: date, before_date: date) -> str:
    after  = after_date.strftime("%Y/%m/%d")
    before = (before_date + timedelta(days=1)).strftime("%Y/%m/%d")
    kw_filter = " OR ".join(f'"{kw}"' for kw in TAX_KEYWORDS)
    return (
        f"has:attachment filename:pdf "
        f"after:{after} before:{before} "
        f"({kw_filter})"
    )


def list_message_ids(service, query: str) -> list[str]:
    ids = []
    page_token = None
    while True:
        kwargs = {"userId": "me", "q": query, "maxResults": PAGE_SIZE}
        if page_token:
            kwargs["pageToken"] = page_token
        response = service.users().messages().list(**kwargs).execute()
        ids.extend(m["id"] for m in response.get("messages", []))
        page_token = response.get("nextPageToken")
        if not page_token:
            break
    return ids


def fetch_message(service, msg_id: str) -> dict:
    return service.users().messages().get(
        userId="me", id=msg_id, format="metadata",
        metadataHeaders=["Subject", "From", "Date"],
    ).execute()


def extract_header(headers: list, name: str) -> str | None:
    for h in headers:
        if h.get("name", "").lower() == name.lower():
            return h.get("value")
    return None


def parse_sender_email(from_header: str | None) -> str | None:
    if not from_header:
        return None
    if "<" in from_header and ">" in from_header:
        return from_header.split("<")[1].rstrip(">").strip()
    return from_header.strip()


def get_pdf_parts(payload: dict) -> list[dict]:
    """Recursively find all PDF attachment parts in a message payload."""
    parts = []
    fname = payload.get("filename", "")
    size  = payload.get("body", {}).get("size", 0)
    if fname.lower().endswith(".pdf") and size > 0:
        parts.append(payload)
    for part in payload.get("parts", []):
        parts.extend(get_pdf_parts(part))
    return parts


def message_to_rows(message: dict) -> list[dict]:
    """Convert a Gmail message API response into one landing row per PDF attachment."""
    payload  = message.get("payload", {})
    headers  = payload.get("headers", [])
    subject  = extract_header(headers, "Subject")
    sender   = parse_sender_email(extract_header(headers, "From"))
    int_date = int(message.get("internalDate", 0))
    received = datetime.fromtimestamp(int_date / 1000, tz=timezone.utc)

    # Strip body data — store metadata only in raw_json
    safe_payload = {k: v for k, v in payload.items() if k != "body"}
    safe_msg = {k: v for k, v in message.items() if k != "payload"}
    safe_msg["payload"] = safe_payload

    rows = []
    for part in get_pdf_parts(payload):
        fname = part.get("filename") or ""
        fext  = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""
        rows.append({
            "source_type":       SOURCE_TYPE,
            "source_id":         message["id"],
            "subject":           subject,
            "sender_email":      sender,
            "received_at":       received,
            "file_name":         fname or None,
            "file_ext":          fext or None,
            "file_size_bytes":   part.get("body", {}).get("size"),
            "raw_json":          safe_msg,
            "_internal_date_ms": int_date,  # for watermark; not inserted
        })
    return rows


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    encryption_key = os.environ["TC_DB_PASSWORD"]
    conn     = get_db_connection(encryption_key)
    batch_id = start_batch(conn)
    log.info(f"Batch {batch_id} started — {WORKFLOW_NAME}")

    rows_extracted    = 0
    rows_loaded       = 0
    rows_skipped      = 0
    max_internal_date = 0

    try:
        service          = get_gmail_service()
        fy_start, fy_end = get_current_fy(conn)
        watermark_ms     = get_watermark(conn)

        if watermark_ms:
            after_date = datetime.fromtimestamp(
                watermark_ms / 1000, tz=timezone.utc
            ).date()
            log.info(f"Incremental run — after {after_date}")
        else:
            after_date = fy_start
            log.info(f"First run — full FY scan from {fy_start} to {fy_end}")

        before_date = min(fy_end, date.today())
        query       = build_gmail_query(after_date, before_date)
        log.info(f"Gmail query: {query}")

        msg_ids = list_message_ids(service, query)
        rows_extracted = len(msg_ids)
        log.info(f"Found {rows_extracted} messages matching query")

        all_rows = []
        for msg_id in msg_ids:
            try:
                message      = fetch_message(service, msg_id)
                message_rows = message_to_rows(message)
                if not message_rows:
                    rows_skipped += 1
                    continue
                all_rows.extend(message_rows)
                max_internal_date = max(
                    max_internal_date,
                    int(message.get("internalDate", 0)),
                )
            except HttpError as e:
                log.warning(f"Skipping message {msg_id} — API error: {e}")
                rows_skipped += 1

        rows_loaded = insert_landing_rows(conn, all_rows, batch_id)
        log.info(f"Landed {rows_loaded} rows into landing.tax_documents")

        if max_internal_date > 0:
            update_watermark(conn, max_internal_date)
            log.info(f"Watermark updated to {max_internal_date}")

        complete_batch(conn, batch_id, "SUCCESS",
                       rows_extracted, rows_loaded, rows_skipped)
        log.info("Batch complete — SUCCESS")

    except FileNotFoundError as e:
        msg = str(e)
        log.error(msg)
        complete_batch(conn, batch_id, "FAILED",
                       rows_extracted, rows_loaded, rows_skipped, msg)
        raise SystemExit(1)

    except HttpError as e:
        if e.resp.status == 401:
            msg = (
                "Gmail OAuth token invalid or expired. "
                "Re-run setup_gmail_auth.py to refresh token.json, "
                "or reconnect the Gmail credential in n8n."
            )
        else:
            msg = f"Gmail API error {e.resp.status}: {e}"
        log.error(msg)
        complete_batch(conn, batch_id, "FAILED",
                       rows_extracted, rows_loaded, rows_skipped, msg)
        raise SystemExit(1)

    except Exception as e:
        msg = f"Unexpected error: {e}"
        log.error(msg)
        complete_batch(conn, batch_id, "FAILED",
                       rows_extracted, rows_loaded, rows_skipped, msg)
        raise SystemExit(1)

    finally:
        conn.close()


if __name__ == "__main__":
    main()
