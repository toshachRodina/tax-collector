# Spec 005 — Gmail Review Bot (Digest Email Approval)

## Status: READY TO BUILD
**Priority**: 2 of 8
**Session**: 2026-04-06

---

## Goal

After each LOAD_CORE_TAX_DOCS run, send a single digest email to `toshach@gmail.com` listing all new `NEEDS_REVIEW` records. Each record has **Confirm** and **Reject** links. Tapping a link on mobile updates `core.tax_documents` and sends a brief confirmation reply. No new apps or accounts required.

---

## Architecture

Two n8n workflows:

```
LOAD_CORE_TAX_DOCS (existing)
  └─ on complete → calls NOTIFY_REVIEW (new)
                     └─ queries NEEDS_REVIEW records
                     └─ if any found → sends digest email (Gmail)
                         └─ user taps Confirm/Reject link
                             └─ REVIEW_ACTION webhook (new)
                                 └─ validates token
                                 └─ UPDATE core.tax_documents
                                 └─ returns success HTML page
```

---

## Security

Each approve/reject link contains an HMAC-SHA256 token:

```
token = HMAC-SHA256(secret, "{doc_id}|{action}")
```

- Secret stored as n8n environment variable: `REVIEW_HMAC_SECRET`
- Without a valid token, the webhook returns 403 and makes no DB change
- Token is one-time-use-safe: attempting to confirm an already-CONFIRMED record is a no-op

---

## Workflow 1: NOTIFY_REVIEW

**Trigger**: Execute Workflow Trigger (called at end of LOAD_CORE_TAX_DOCS)
**Also**: Manual Trigger (for testing)

### Nodes

| Node | Type | Action |
|------|------|--------|
| Trigger | executeWorkflowTrigger + manualTrigger | Entry point |
| Get Pending | Postgres | Query NEEDS_REVIEW records |
| Any Pending? | IF | Count > 0 → continue, else → stop |
| Build Email | Code | Generate HTML digest with approve/reject links |
| Send Digest | Gmail | Send to toshach@gmail.com |
| Log | Postgres | Insert to ctl.process_log |

### Get Pending SQL

```sql
SELECT
    d.doc_id,
    d.supplier_name,
    d.subject,
    c.category_nme   AS category,
    d.confidence_score,
    d.total_amount,
    d.document_date,
    d.fy_label
FROM core.tax_documents d
LEFT JOIN ref.tax_categories c ON c.category_id = d.tax_category_id
WHERE d.review_status = 'NEEDS_REVIEW'
ORDER BY d.confidence_score ASC, d.document_date DESC;
```

### Link format

```
https://n8n.rodinah.dev/webhook/tax-review?action=confirm&doc_id=123&token=<hmac>
https://n8n.rodinah.dev/webhook/tax-review?action=reject&doc_id=123&token=<hmac>
```

### Email format

- Subject: `TC Review Required — N documents awaiting decision`
- Body: HTML table, one row per document
- Columns: Doc ID | Supplier | Subject | Category | Confidence | Amount | FY | [✓ Confirm] [✗ Reject]
- Footer: link to Metabase Review Queue dashboard

---

## Workflow 2: REVIEW_ACTION (Webhook)

**Trigger**: Webhook GET at path `/tax-review`
**Response mode**: `responseNode` (returns custom HTML)

### Nodes

| Node | Type | Action |
|------|------|--------|
| Webhook | Webhook | Receives action, doc_id, token |
| Validate Token | Code | Recompute HMAC, compare — return 403 if mismatch |
| Check Action | IF | `action == confirm` → confirm branch, else → reject branch |
| Update Confirm | Postgres | SET review_status = 'CONFIRMED' WHERE doc_id = ? |
| Update Reject | Postgres | SET review_status = 'REJECTED' WHERE doc_id = ? |
| Respond | Respond to Webhook | Return success HTML page |

### Success response HTML

Simple mobile-friendly page:
- ✓ or ✗ icon
- "Confirmed: [Supplier Name]" or "Rejected: [Supplier Name]"
- Link to Metabase Review Queue: `http://hal-srvr:3002/dashboard/6`

---

## Integration with LOAD_CORE_TAX_DOCS

Add a final node to the existing `LOAD_CORE_TAX_DOCS` workflow:

- After **Complete Batch** → call **NOTIFY_REVIEW** via Execute Workflow node
- Pass no data (NOTIFY_REVIEW queries the DB itself)
- Fire-and-forget (don't block on the result)

---

## Environment Variable Required

Add to `homelab-hub` docker-compose (n8n service):

```yaml
REVIEW_HMAC_SECRET: "choose-a-random-string-here"
```

---

## Done Criteria

- [ ] `REVIEW_HMAC_SECRET` added to docker-compose and n8n restarted
- [ ] NOTIFY_REVIEW workflow created and tested (manual trigger sends email)
- [ ] Email renders correctly on mobile: table readable, links tappable
- [ ] REVIEW_ACTION webhook live at `n8n.rodinah.dev/webhook/tax-review`
- [ ] Tapping Confirm link → record CONFIRMED in DB, success page shown
- [ ] Tapping Reject link → record REJECTED in DB, success page shown
- [ ] Double-tap safe: re-tapping a link is a no-op (already CONFIRMED/REJECTED)
- [ ] LOAD_CORE_TAX_DOCS calls NOTIFY_REVIEW on completion
- [ ] No email sent if zero NEEDS_REVIEW records

---

## Out of Scope

- Per-record notes via email (add notes via DBeaver or future UI)
- WhatsApp / Signal integration
- Push notifications
