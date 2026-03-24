# Feature Spec 002 — Gmail Scanner

**Status**: Draft
**Created**: 2026-03-24
**Depends on**: 001-database-schema
**Blocks**: None (parallel to 003, 004)

---

## 1. Overview

The Gmail Scanner is the first document extraction pipeline. It connects to a Gmail inbox via the Gmail API (OAuth2), searches for emails containing tax-relevant attachments within the current Australian financial year (July 1 – June 30), extracts metadata for each matching attachment, and lands that metadata into `landing.tax_documents`.

No attachment content is downloaded. Only metadata is extracted: subject, sender, received date, filename, file extension, file size, and the full Gmail message metadata as JSON. This satisfies the data privacy rule (no content sent to cloud APIs).

The pipeline is driven by an n8n workflow (`TC_EXTRACT_GMAIL`) and implemented in `prod/scripts/extract_gmail_tax_docs.py`. It uses watermark-based incremental loading — on each run it only processes messages newer than the last successfully processed message.

---

## 2. Gmail OAuth Setup (Detailed)

### 2.1 The 7-Day Token Expiry Problem

OAuth refresh tokens for apps using sensitive Gmail scopes (`gmail.readonly`) expire every 7 days when the Google Cloud project OAuth consent screen is in **Testing** mode. This is a hard Google restriction — it cannot be overridden in Testing mode.

**Symptom**: The n8n Gmail credential stops working every 7 days. Pipelines fail with 401 Unauthorized errors. Manual re-auth in n8n is required.

**Fix**: Publish the OAuth app (move from Testing → In production). Once published, refresh tokens do not expire unless manually revoked or inactive for 6+ months.

### 2.2 Step-by-Step: Publish the OAuth App

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and select the Google Cloud project used for this integration.
2. Navigate to **APIs & Services → OAuth consent screen**.
3. The current Publishing status shows **Testing**. Click **Publish App**.
4. A warning dialog appears about Google verification. This app does **not** need to pass Google verification — verification is only required if you want external users (other Google accounts) to authorise it. For personal use on your own Gmail account, click **Confirm** / accept the warning and proceed.
5. The status changes to **In production**.
6. In n8n (`192.168.0.250:5678`): go to **Credentials → Gmail OAuth2** (or whichever credential is used for Gmail).
7. **Disconnect** the credential (revoke the current token).
8. **Reconnect** — go through the Google OAuth consent flow once more to obtain a fresh refresh token under the now-published app.
9. The new refresh token will not expire automatically. It will only expire if manually revoked in Google Account settings or after 6 months of complete inactivity.

### 2.3 Re-auth If Ever Needed Again

If the token is manually revoked or the credential is deleted:
- Repeat step 6–8 above (reconnect in n8n).
- The workflow must detect 401 errors and send a notification — see Section 8.

---

## 3. Scope & Access

### 3.1 Gmail API

- **API**: Gmail API v1 — must be enabled on the Google Cloud project.
- **OAuth scope**: `https://www.googleapis.com/auth/gmail.readonly` — read-only access to messages and metadata. No write, send, or delete permissions.
- **Access type**: Offline (to obtain a refresh token).

### 3.2 What Is Accessed

- Email message metadata: subject, sender, date, headers.
- Attachment part metadata: filename, MIME type, size. The attachment `body.data` payload is **not** fetched.
- No email body content is read or stored.

### 3.3 What Is Not Accessed

- Email body text or HTML.
- Attachment file content (binary data).
- Contacts, calendar, Drive, or any other Google service.

---

## 4. What Gets Extracted

For each Gmail message matching the search query (see Section 5), the script extracts:

| Field | Source | Notes |
|---|---|---|
| `source_type` | Hardcoded | Always `'GMAIL'` |
| `source_id` | `message.id` | Gmail message ID — globally unique, used as dedup key |
| `subject` | `message.payload.headers` where `name = 'Subject'` | May be NULL if no subject |
| `sender_email` | `message.payload.headers` where `name = 'From'` | Extract email address from display name + address string |
| `received_at` | `message.internalDate` | Epoch milliseconds → convert to TIMESTAMPTZ |
| `file_name` | `part.filename` | From attachment MIME part |
| `file_ext` | Derived from `file_name` | Lowercase extension, e.g. `pdf`, `xlsx` |
| `file_size_bytes` | `part.body.size` | Integer bytes |
| `raw_json` | Full `message` object from API | Stored as JSONB; excludes body payload data |

**One row per attachment.** If a message has three PDF attachments, three rows are inserted into `landing.tax_documents`, all with the same `source_id` (Gmail message ID) but different `file_name` values.

**Messages without attachments are skipped** — the Gmail search query uses `has:attachment filename:pdf` so this should be rare, but the script validates that each message has at least one attachment part before inserting.

---

## 5. Search Query Logic

### 5.1 Query Template

```python
def build_gmail_query(fy_start: date, fy_end: date) -> str:
    """
    Build Gmail search query for tax-relevant PDF attachments in the given FY window.
    fy_start: e.g. date(2024, 7, 1)
    fy_end:   e.g. date(2025, 6, 30)
    """
    after  = fy_start.strftime("%Y/%m/%d")
    before = (fy_end + timedelta(days=1)).strftime("%Y/%m/%d")  # Gmail 'before' is exclusive

    keywords = [
        "invoice", "statement", "receipt", "tax", "ATO", "deduction",
        "interest", "dividend", "insurance", "payslip", "group certificate",
        "HECS", "superannuation", "depreciation"
    ]
    kw_filter = " OR ".join(f'"{kw}"' for kw in keywords)

    return (
        f"has:attachment filename:pdf "
        f"after:{after} before:{before} "
        f"({kw_filter})"
    )
```

### 5.2 Incremental Override

On incremental runs (when a watermark exists), the `after:` date in the query is replaced with the watermark date. See Section 6.

### 5.3 Query Notes

- `filename:pdf` is case-insensitive in Gmail — covers both `.pdf` and `.PDF`.
- `has:attachment` is redundant with `filename:pdf` but kept for clarity.
- The `before:` date is set to `fy_end + 1 day` because Gmail's `before:` filter is exclusive (i.e. `before:2025/07/01` means up to and including 2025-06-30).
- Keyword phrases containing spaces (e.g. "group certificate") are quoted in the Gmail query string.

---

## 6. Watermark / Incremental Strategy

### 6.1 Watermark Table

The watermark is stored in `ctl.ctrl_vars` as a plain (non-encrypted) timestamp string under:
- `package_nme = 'TC_EXTRACT_GMAIL'`
- `var_nme = 'LAST_INTERNAL_DATE_MS'`
- `var_val` = Gmail `internalDate` of the most recently processed message (epoch milliseconds as a string), encrypted at rest via pgcrypto per the existing table design.

Alternatively, if `ctl.ctrl_vars` encryption overhead is undesirable for a non-secret value, a dedicated row can use a plaintext sentinel. The implementation decision is left to the developer — document the choice in a code comment.

### 6.2 First Run (No Watermark)

- No row exists in `ctl.ctrl_vars` for `('TC_EXTRACT_GMAIL', 'LAST_INTERNAL_DATE_MS')`.
- The script queries Gmail for the **entire current FY** (July 1 of the current FY year through today's date, capped at June 30 if today is after June 30).
- Current FY is determined by querying `ref.fy_periods WHERE is_current = TRUE`.

### 6.3 Incremental Run (Watermark Exists)

- Read `LAST_INTERNAL_DATE_MS` from `ctl.ctrl_vars`.
- Convert to a `date` and pass as the `after:` parameter in the Gmail query.
- Only messages with `internalDate > watermark` are processed.

### 6.4 Updating the Watermark

- After all rows from a run are successfully inserted into `landing.tax_documents` and the `ctl.process_log` row is updated to `SUCCESS`, the watermark is updated to the maximum `internalDate` seen in the current batch.
- The watermark is **not** updated if the run fails or is PARTIAL — the next run will reprocess the same window.

```python
def update_watermark(conn, new_internal_date_ms: int) -> None:
    sql = """
        INSERT INTO ctl.ctrl_vars (package_nme, var_nme, var_val, description)
        VALUES (
            'TC_EXTRACT_GMAIL',
            'LAST_INTERNAL_DATE_MS',
            pgp_sym_encrypt(%s::text, current_setting('app.encryption_key')),
            'Watermark: max Gmail internalDate (epoch ms) from last successful run'
        )
        ON CONFLICT (package_nme, var_nme)
        DO UPDATE SET
            var_val    = pgp_sym_encrypt(%s::text, current_setting('app.encryption_key')),
            updated_at = NOW();
    """
    with conn.cursor() as cur:
        val = str(new_internal_date_ms)
        cur.execute(sql, (val, val))
    conn.commit()
```

---

## 7. Landing → Core Flow

### 7.1 Landing Table: `landing.tax_documents`

The landing table must exist before this script runs (created in spec 001). Schema for reference:

```sql
CREATE TABLE landing.tax_documents (
    landing_id          SERIAL PRIMARY KEY,
    source_type         VARCHAR(20)  NOT NULL,           -- 'GMAIL', 'FOLDER', 'ONEDRIVE'
    source_id           VARCHAR(500) NOT NULL,           -- dedup key (Gmail message ID)
    subject             TEXT,
    sender_email        VARCHAR(500),
    received_at         TIMESTAMPTZ,
    file_name           VARCHAR(500),
    file_ext            VARCHAR(20),
    file_size_bytes     INTEGER,
    raw_json            JSONB,
    batch_id            INTEGER REFERENCES ctl.process_log(batch_id),
    landed_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_type, source_id, file_name)           -- dedup: same message + same attachment
);
```

Note: The `UNIQUE (source_type, source_id, file_name)` constraint prevents duplicate inserts on rerun. The Python script uses `INSERT ... ON CONFLICT DO NOTHING` to handle this gracefully.

### 7.2 Stored Procedure: `sp_merge_tax_documents`

This stored proc is called by a separate n8n step (or a follow-on Python call) after landing is complete. It merges `landing.tax_documents` → `core.tax_documents`, deduplicating on `(source_type, source_id, file_name)`.

The stored proc is defined in `prod/stored_procedures/sp_merge_tax_documents.sql` (created in a later spec or alongside this feature). The Gmail scanner script is responsible only for the landing step.

### 7.3 Row-per-Attachment Insert Pattern

```python
def insert_landing_rows(conn, rows: list[dict], batch_id: int) -> int:
    sql = """
        INSERT INTO landing.tax_documents
            (source_type, source_id, subject, sender_email, received_at,
             file_name, file_ext, file_size_bytes, raw_json, batch_id)
        VALUES
            (%(source_type)s, %(source_id)s, %(subject)s, %(sender_email)s,
             %(received_at)s, %(file_name)s, %(file_ext)s, %(file_size_bytes)s,
             %(raw_json)s, %(batch_id)s)
        ON CONFLICT (source_type, source_id, file_name) DO NOTHING;
    """
    inserted = 0
    with conn.cursor() as cur:
        for row in rows:
            cur.execute(sql, {**row, "batch_id": batch_id})
            inserted += cur.rowcount
    conn.commit()
    return inserted
```

---

## 8. Error Handling & Auth Monitoring

### 8.1 Auth Failure Detection (401 Errors)

The Gmail API client raises `googleapiclient.errors.HttpError` with status 401 when the token is invalid or expired.

```python
from googleapiclient.errors import HttpError

try:
    results = service.users().messages().list(userId="me", q=query).execute()
except HttpError as e:
    if e.resp.status == 401:
        log_failure(conn, batch_id, "Gmail OAuth token invalid or expired. "
                    "Re-authorise at n8n > Credentials > Gmail OAuth2.")
        raise SystemExit(1)
    raise
```

The `log_failure` call writes `status='FAILED'` and the error message to `ctl.process_log`.

### 8.2 n8n Error Notification

The `TC_EXTRACT_GMAIL` n8n workflow must include an error branch:

- **Trigger**: The Python script exits with a non-zero exit code, OR the Execute Command node detects stderr output.
- **Action**: Send a Telegram message (or email fallback) with the text:
  > "Tax Collector — Gmail scanner failed. Check ctl.process_log for details. If error is auth-related: go to n8n > Credentials > Gmail OAuth2 and reconnect."
- **Log**: Also insert/update the `ctl.process_log` row to `status='FAILED'` with `error_msg` populated.

### 8.3 Other Error Handling

| Error | Behaviour |
|---|---|
| DB connection failure | Log to stderr, exit 1 (no process_log row possible — handle in n8n) |
| Gmail API quota exceeded (429) | Retry with exponential backoff up to 3 times, then fail |
| Individual message fetch failure | Log a warning, skip the message, increment `rows_skipped`, continue |
| No messages returned by query | Log `rows_extracted=0`, status=`SUCCESS` — not an error |
| Message has no PDF attachments | Skip silently (should not occur given `filename:pdf` query filter) |

### 8.4 Batch ID Pattern

```python
import datetime

WORKFLOW_NAME = "TC_EXTRACT_GMAIL"
SCRIPT_NAME   = "extract_gmail_tax_docs.py"

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
        SET status        = %s,
            rows_extracted = %s,
            rows_loaded   = %s,
            rows_skipped  = %s,
            error_msg     = %s,
            completed_at  = NOW()
        WHERE batch_id = %s;
    """
    with conn.cursor() as cur:
        cur.execute(sql, (status, rows_extracted, rows_loaded, rows_skipped,
                          error_msg, batch_id))
    conn.commit()
```

---

## 9. Python Script Design

### 9.1 File Location

```
prod/scripts/extract_gmail_tax_docs.py
```

### 9.2 Dependencies

```
google-api-python-client>=2.0
google-auth-oauthlib>=1.0
google-auth-httplib2>=0.1
psycopg2-binary>=2.9
```

These must be installed in the execution environment on the Ubuntu server.

### 9.3 Environment Variables

| Variable | Purpose |
|---|---|
| `TC_DB_PASSWORD` | PostgreSQL password for `taxcollectorusr` |
| `GOOGLE_CREDENTIALS_JSON` | Path to OAuth credentials JSON file, OR the JSON content as a string |
| `GOOGLE_TOKEN_JSON` | Path to the token file (access + refresh tokens), OR token JSON as a string |

When run via n8n's Execute Command node, n8n injects these as environment variables from its credential store.

### 9.4 Script Skeleton

```python
#!/usr/bin/env python3
"""
extract_gmail_tax_docs.py
Tax Collector — Gmail Scanner
Extracts tax-relevant PDF attachment metadata from Gmail into landing.tax_documents.
"""

import os
import json
import base64
import logging
from datetime import date, timedelta, datetime, timezone

import psycopg2
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google.oauth2.credentials import Credentials

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

WORKFLOW_NAME  = "TC_EXTRACT_GMAIL"
SCRIPT_NAME    = "extract_gmail_tax_docs.py"
SOURCE_TYPE    = "GMAIL"
SCOPES         = ["https://www.googleapis.com/auth/gmail.readonly"]
PAGE_SIZE      = 500   # Gmail API max per page


def get_db_connection():
    return psycopg2.connect(
        host="192.168.0.250",
        port=5432,
        database="taxcollectordb",
        user="taxcollectorusr",
        password=os.environ["TC_DB_PASSWORD"],
        options="-c app.encryption_key=" + os.environ["TC_DB_PASSWORD"]
        # encryption key reuses DB password — consistent with ctl.ctrl_vars design
    )


def get_gmail_service():
    token_json = os.environ.get("GOOGLE_TOKEN_JSON")
    creds = Credentials.from_authorized_user_info(json.loads(token_json), SCOPES)
    return build("gmail", "v1", credentials=creds)


def get_current_fy(conn) -> tuple[date, date]:
    with conn.cursor() as cur:
        cur.execute("SELECT start_date, end_date FROM ref.fy_periods WHERE is_current = TRUE;")
        row = cur.fetchone()
    if not row:
        raise RuntimeError("No current FY found in ref.fy_periods")
    return row[0], row[1]


def get_watermark(conn) -> int | None:
    sql = """
        SELECT pgp_sym_decrypt(var_val, current_setting('app.encryption_key'))
        FROM ctl.ctrl_vars
        WHERE package_nme = 'TC_EXTRACT_GMAIL' AND var_nme = 'LAST_INTERNAL_DATE_MS';
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        row = cur.fetchone()
    return int(row[0]) if row else None


def build_gmail_query(after_date: date, before_date: date) -> str:
    after  = after_date.strftime("%Y/%m/%d")
    before = (before_date + timedelta(days=1)).strftime("%Y/%m/%d")
    keywords = [
        "invoice", "statement", "receipt", "tax", "ATO", "deduction",
        "interest", "dividend", "insurance", "payslip", "group certificate",
        "HECS", "superannuation", "depreciation"
    ]
    kw_filter = " OR ".join(f'"{kw}"' for kw in keywords)
    return f'has:attachment filename:pdf after:{after} before:{before} ({kw_filter})'


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
        metadataHeaders=["Subject", "From", "Date"]
    ).execute()


def extract_header(headers: list, name: str) -> str | None:
    for h in headers:
        if h.get("name", "").lower() == name.lower():
            return h.get("value")
    return None


def parse_sender_email(from_header: str | None) -> str | None:
    if not from_header:
        return None
    # "Display Name <email@example.com>" → "email@example.com"
    if "<" in from_header and ">" in from_header:
        return from_header.split("<")[1].rstrip(">").strip()
    return from_header.strip()


def get_pdf_parts(payload: dict) -> list[dict]:
    """Recursively find all PDF attachment parts in the message payload."""
    parts = []
    if payload.get("filename", "").lower().endswith(".pdf") and payload.get("body", {}).get("size", 0) > 0:
        parts.append(payload)
    for part in payload.get("parts", []):
        parts.extend(get_pdf_parts(part))
    return parts


def message_to_rows(message: dict, batch_id: int) -> list[dict]:
    payload  = message.get("payload", {})
    headers  = payload.get("headers", [])
    subject  = extract_header(headers, "Subject")
    sender   = parse_sender_email(extract_header(headers, "From"))
    int_date = int(message.get("internalDate", 0))
    received = datetime.fromtimestamp(int_date / 1000, tz=timezone.utc)

    # Strip body data from raw_json before storing — metadata only
    safe_msg = {k: v for k, v in message.items() if k != "payload"}
    safe_msg["payload"] = {k: v for k, v in payload.items() if k != "body"}

    rows = []
    for part in get_pdf_parts(payload):
        fname = part.get("filename") or ""
        fext  = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""
        rows.append({
            "source_type":      SOURCE_TYPE,
            "source_id":        message["id"],
            "subject":          subject,
            "sender_email":     sender,
            "received_at":      received,
            "file_name":        fname,
            "file_ext":         fext,
            "file_size_bytes":  part.get("body", {}).get("size"),
            "raw_json":         json.dumps(safe_msg),
            "batch_id":         batch_id,
            "_internal_date_ms": int_date   # used for watermark update, not inserted
        })
    return rows


def main():
    conn    = get_db_connection()
    batch_id = start_batch(conn)
    log.info(f"Started batch {batch_id}")

    rows_extracted = 0
    rows_loaded    = 0
    rows_skipped   = 0
    max_internal_date = 0

    try:
        service          = get_gmail_service()
        fy_start, fy_end = get_current_fy(conn)
        watermark_ms     = get_watermark(conn)

        if watermark_ms:
            after_date = datetime.fromtimestamp(watermark_ms / 1000, tz=timezone.utc).date()
            log.info(f"Incremental run: after {after_date}")
        else:
            after_date = fy_start
            log.info(f"First run: full FY scan from {fy_start}")

        before_date = min(fy_end, date.today())
        query       = build_gmail_query(after_date, before_date)
        log.info(f"Gmail query: {query}")

        msg_ids = list_message_ids(service, query)
        rows_extracted = len(msg_ids)
        log.info(f"Found {rows_extracted} messages")

        all_rows = []
        for msg_id in msg_ids:
            try:
                message      = fetch_message(service, msg_id)
                message_rows = message_to_rows(message, batch_id)
                if not message_rows:
                    rows_skipped += 1
                    continue
                all_rows.extend(message_rows)
                max_internal_date = max(
                    max_internal_date,
                    int(message.get("internalDate", 0))
                )
            except HttpError as e:
                log.warning(f"Skipping message {msg_id}: {e}")
                rows_skipped += 1

        rows_loaded = insert_landing_rows(conn, all_rows, batch_id)
        log.info(f"Inserted {rows_loaded} rows into landing.tax_documents")

        if max_internal_date > 0:
            update_watermark(conn, max_internal_date)

        complete_batch(conn, batch_id, "SUCCESS",
                       rows_extracted, rows_loaded, rows_skipped)
        log.info("Batch complete — SUCCESS")

    except HttpError as e:
        msg = f"Gmail API error {e.resp.status}: {e}"
        if e.resp.status == 401:
            msg = ("Gmail OAuth token invalid or expired. "
                   "Re-authorise at n8n > Credentials > Gmail OAuth2 and reconnect.")
        log.error(msg)
        complete_batch(conn, batch_id, "FAILED", rows_extracted, rows_loaded, rows_skipped, msg)
        raise SystemExit(1)
    except Exception as e:
        log.error(f"Unexpected error: {e}")
        complete_batch(conn, batch_id, "FAILED", rows_extracted, rows_loaded, rows_skipped, str(e))
        raise SystemExit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
```

---

## 10. n8n Workflow: TC_EXTRACT_GMAIL

### 10.1 Workflow Location

- **Development name**: `WIP_TC_EXTRACT_GMAIL`
- **n8n folder**: `personal > tax-collector > wip`
- **Promoted name**: `TC_EXTRACT_GMAIL` (moved to `personal > tax-collector` on approval)

### 10.2 Workflow Nodes

```
[Schedule Trigger]
    ↓  Daily at 06:00 AEST
[Set Environment Variables]
    ↓  Inject TC_DB_PASSWORD, GOOGLE_TOKEN_JSON from n8n credentials
[Execute Command: python3 /opt/tax-collector/scripts/extract_gmail_tax_docs.py]
    ↓  On success
[HTTP Request or Postgres: call sp_merge_tax_documents]
    ↓  On success
[Telegram Notify: "TC_EXTRACT_GMAIL completed — N rows loaded"]
    ↓  On any error (error branch from Execute Command)
[Telegram Notify: "TC_EXTRACT_GMAIL FAILED — check ctl.process_log. If 401: re-auth Gmail credential in n8n."]
```

### 10.3 Schedule

- Trigger: **Daily at 06:00 AEST** (20:00 UTC previous day).
- Manual trigger also available for ad-hoc runs.

### 10.4 Credential Bindings in n8n

The Execute Command node must pass environment variables explicitly:

```
TC_DB_PASSWORD     → from n8n credential "Tax Collector DB Password"
GOOGLE_TOKEN_JSON  → from n8n credential "Gmail OAuth Token JSON"
```

These are set as environment variables on the Execute Command node, not as inline arguments.

### 10.5 Error Branch

- Any non-zero exit code from the Python script triggers the error branch.
- The error branch sends a Telegram message with enough context for the user to diagnose (see Section 8.2).
- The error branch does **not** retry automatically — flapping retries could cause partial duplicate loads or mask auth errors. Fix the root cause and re-run manually.

---

## 11. Acceptance Criteria

### 11.1 First Run

- Given no watermark exists in `ctl.ctrl_vars`
- When the script runs successfully
- Then:
  - `ctl.process_log` has a row with `workflow_nme='TC_EXTRACT_GMAIL'`, `status='SUCCESS'`
  - `landing.tax_documents` has rows with `source_type='GMAIL'` for each PDF attachment found
  - `ctl.ctrl_vars` has a row for `('TC_EXTRACT_GMAIL', 'LAST_INTERNAL_DATE_MS')` with a valid epoch ms value
  - No email body content appears in `raw_json`

### 11.2 Incremental Run

- Given a watermark exists from a prior run
- When the script runs again on the same day (no new mail)
- Then:
  - `rows_extracted = 0`, `status='SUCCESS'`
  - No duplicate rows in `landing.tax_documents`
  - Watermark is unchanged

### 11.3 Deduplication

- Given a message was already landed in a previous run
- When the script re-encounters the same message ID + filename
- Then: `ON CONFLICT DO NOTHING` fires, `rows_loaded` count reflects only net-new rows

### 11.4 Auth Failure

- Given the Gmail OAuth token is revoked or expired
- When the script runs
- Then:
  - `ctl.process_log` row has `status='FAILED'` and `error_msg` containing "re-authorise"
  - Script exits with code 1
  - n8n error branch fires and sends a Telegram notification

### 11.5 No Matching Emails

- Given the Gmail query returns zero results
- When the script runs
- Then:
  - `status='SUCCESS'`, `rows_extracted=0`, `rows_loaded=0`
  - No error, no notification

### 11.6 Multi-Attachment Email

- Given an email has 3 PDF attachments
- When the script processes it
- Then: 3 rows appear in `landing.tax_documents` with the same `source_id` but different `file_name` values

### 11.7 OAuth Persistence

- Given the Google Cloud project OAuth app is published (In production)
- When the Gmail credential in n8n is reconnected once after publishing
- Then: the credential remains valid beyond 7 days with no re-auth required

---

## 12. Open Items

- [ ] **Token storage format**: Confirm whether `GOOGLE_TOKEN_JSON` will be injected as a JSON string env var or as a file path from the Ubuntu server filesystem. If file path, update `get_gmail_service()` to use `Credentials.from_authorized_user_file()` instead.
- [ ] **Encryption key for `ctl.ctrl_vars`**: The watermark uses `pgp_sym_encrypt` with `app.encryption_key` set via connection options. Confirm the watermark value (a timestamp, not a secret) warrants encryption — or use a simpler unencrypted config table if added to spec 001 as `ctl.pipeline_config`.
- [ ] **Script deployment path on Ubuntu**: Confirm the target path (`/opt/tax-collector/scripts/` assumed). Update n8n workflow command path and `deploy-scripts.bat` accordingly.
- [ ] **sp_merge_tax_documents**: This stored proc is referenced in Section 7.2 but not yet specced. It should be included in spec 001's DDL section or in a new spec 002a. It must be created before the merge step in n8n can run.
- [ ] **Telegram bot config**: Confirm the Telegram bot token and chat ID to use for notifications are already stored in n8n credentials from the shared infrastructure setup.
- [ ] **`landing.tax_documents` DDL in spec 001**: Verify the `UNIQUE (source_type, source_id, file_name)` constraint is included in the 001 DDL. If not, add it before implementing this spec.
