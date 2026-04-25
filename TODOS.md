# TODOS

Items deferred from planning sessions. Prioritized P1–P3.

---

## P2 — Ollama confidence fallback (Phase 10 prerequisite)

**File:** `prod/scripts/process_document.py`

When Phase 10 adds the confidence field to the Ollama JSON response, the parser must
not crash if Ollama omits the field. Use a graceful fallback:

```python
classification_confidence = response.get('confidence', 'LOW')
```

Build this into the Phase 10 prompt update. Do not assume the field is always present —
Ollama occasionally returns partial JSON under load.

---

## P3 — Task Scheduler silent-failure detection (Phase 8 prerequisite)

**File:** `prod/workflows/TC_COMPLETENESS_ALERT.json` (Phase 8 n8n workflow)

The weekly completeness alerting job (Phase 8) has no visibility into whether the
FY2026 WFH Task Scheduler job (`log_wfh_day.ps1`) is still firing. Windows updates
or script errors can silently break it.

Add a check to the completeness alert n8n workflow:

- If today is a weekday AND the current date is within FY2026 (after 1 Jul 2025)
- AND `SELECT COUNT(*) FROM ctl.wfh_log WHERE wfh_date >= CURRENT_DATE - 7` returns 0
- Append a warning to the alert email: "No WFH entries in the past 7 days — check
  Task Scheduler on the Windows dev machine."

Piggybacks on the same n8n job as Phase 8. Build when Phase 8 is implemented.
