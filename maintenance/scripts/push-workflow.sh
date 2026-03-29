#!/usr/bin/env bash
# push-workflow.sh — Push a workflow JSON to the running n8n instance via API
#
# Usage:
#   bash maintenance/scripts/push-workflow.sh prod/workflows/WIP_TC_EXTRACT_GMAIL.json
#
# The workflow JSON should contain a top-level "_n8nId" field with the n8n workflow ID.
# This field is stripped before sending to the API.
#
#   - If "_n8nId" is present → UPDATE that workflow in place
#   - If "_n8nId" is absent  → CREATE new, then print the new ID to add to the JSON
#
# All JSON parsing happens on the server (jq is available there).

set -euo pipefail

WORKFLOW_FILE="${1:-}"
if [[ -z "$WORKFLOW_FILE" || ! -f "$WORKFLOW_FILE" ]]; then
    echo "ERROR: Usage: $0 <path-to-workflow.json>"
    exit 1
fi

SSH_KEY="$HOME/.ssh/trade_vantage_agent"
SSH_HOST="howieds@192.168.0.250"
N8N_URL="http://localhost:5678"
API_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI5ZmU3ODMyOS0zNWM3LTQ1MjYtOGYyMS1mZmNmNjY1ZGFhOWQiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiOTJkMTRiODItMTM0YS00OGE0LTgwZjAtYTY5ZDJjZWViMTQxIiwiaWF0IjoxNzc0MTMwNzE3fQ.LGBl1AzEXeKNxwOlBW41Sw6sAep36XjkgQMDn3jyoYY"
REMOTE_TMP="/tmp/tc_wf_push.json"

echo "Copying $WORKFLOW_FILE to server..."
scp -q -i "$SSH_KEY" "$WORKFLOW_FILE" "$SSH_HOST:$REMOTE_TMP"

echo "Pushing to n8n..."
ssh -i "$SSH_KEY" "$SSH_HOST" bash <<SSHEOF
set -e

WF_NAME=\$(jq -r '.name' "$REMOTE_TMP")
WF_ID=\$(jq -r '._n8nId // empty' "$REMOTE_TMP")
echo "  Workflow: \$WF_NAME"

# Strip _n8nId and other non-API fields before sending
jq '{name: .name, nodes: .nodes, connections: .connections, settings: (.settings | {executionOrder, saveManualExecutions, executionTimeout, errorWorkflow} | with_entries(select(.value != null)))}' "$REMOTE_TMP" > "${REMOTE_TMP}.api"

if [[ -n "\$WF_ID" ]]; then
    echo "  ID from JSON: \$WF_ID — updating in place..."
    RESULT=\$(curl -s -X PUT "$N8N_URL/api/v1/workflows/\$WF_ID" \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary @"${REMOTE_TMP}.api")
    STATUS=\$(echo "\$RESULT" | jq -r '.id // "ERROR"')
    if [[ "\$STATUS" == "ERROR" || "\$STATUS" == "null" ]]; then
        echo "  ERROR: \$(echo \$RESULT | jq -r '.message // .error // "unknown error"')"
        exit 1
    fi
    echo "  Updated: \$(echo "\$RESULT" | jq -r '.name') | id=\$(echo "\$RESULT" | jq -r '.id') | nodes=\$(echo "\$RESULT" | jq '.nodes | length')"
else
    echo "  No _n8nId in JSON — creating new workflow..."
    RESULT=\$(curl -s -X POST "$N8N_URL/api/v1/workflows" \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary @"${REMOTE_TMP}.api")
    NEW_ID=\$(echo "\$RESULT" | jq -r '.id // "ERROR"')
    if [[ "\$NEW_ID" == "ERROR" || "\$NEW_ID" == "null" ]]; then
        echo "  ERROR: \$(echo \$RESULT | jq -r '.message // .error // "unknown error"')"
        exit 1
    fi
    echo "  Created: \$(echo "\$RESULT" | jq -r '.name') | id=\$NEW_ID | nodes=\$(echo "\$RESULT" | jq '.nodes | length')"
    echo ""
    echo "  ACTION REQUIRED: Add this to the workflow JSON:"
    echo "    \"_n8nId\": \"\$NEW_ID\","
fi

rm -f "$REMOTE_TMP" "${REMOTE_TMP}.api"
SSHEOF

echo "Done. Refresh n8n UI to see changes."
