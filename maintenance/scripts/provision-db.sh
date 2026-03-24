#!/usr/bin/env bash
# =============================================================================
# provision-db.sh
# Provisions the taxcollectordb schema on the Ubuntu server.
# Run from the dev machine (Windows) or directly on the server.
#
# USAGE (from Windows PowerShell or WSL):
#   bash maintenance/scripts/provision-db.sh
#
# PREREQUISITES:
#   1. Set TC_DB_PASSWORD environment variable:
#        export TC_DB_PASSWORD=your_password
#   2. Set POSTGRES_SUPERUSER_PASSWORD (postgres superuser) for step 000:
#        export POSTGRES_SUPERUSER_PASSWORD=your_superuser_password
#   3. Ensure psql is installed locally OR run this directly on the server.
#
# The script copies DDL files to the server via the X: drive mapping and then
# executes them via SSH. Adjust SERVER_DDL_PATH if your mount differs.
# =============================================================================

set -euo pipefail

DB_HOST="192.168.0.250"
DB_PORT="5432"
DB_NAME="taxcollectordb"
DB_USER="taxcollectorusr"
DDL_DIR="$(cd "$(dirname "$0")/../../prod/schema/DDL" && pwd)"
SERVER_DDL_PATH="/tmp/taxcollector_ddl"
SSH_USER="howieds"
SERVER_HOST="192.168.0.250"

# Validate required env vars
if [[ -z "${TC_DB_PASSWORD:-}" ]]; then
    echo "ERROR: TC_DB_PASSWORD is not set."
    echo "  Run: export TC_DB_PASSWORD=your_password"
    exit 1
fi

echo "=== Tax Collector DB Provisioning ==="
echo "Host: $DB_HOST:$DB_PORT | DB: $DB_NAME"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Copy DDL files to server /tmp
# ---------------------------------------------------------------------------
echo ">>> Step 1: Copying DDL files to server..."
ssh "$SSH_USER@$SERVER_HOST" "mkdir -p $SERVER_DDL_PATH"
scp "$DDL_DIR"/*.sql "$SSH_USER@$SERVER_HOST:$SERVER_DDL_PATH/"
echo "    DDL files copied to $SERVER_DDL_PATH"

# ---------------------------------------------------------------------------
# Step 2: Run 000_prerequisites.sql as postgres superuser
# This creates the DB, user, schemas, and extensions.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 2: Running prerequisites (as postgres superuser)..."
echo "    You may be prompted for the postgres superuser password."

# Substitute the real password into a temp copy (never committed to repo)
ssh "$SSH_USER@$SERVER_HOST" "
    sed 's/REPLACE_WITH_TC_DB_PASSWORD/$TC_DB_PASSWORD/g' \
        $SERVER_DDL_PATH/000_prerequisites.sql \
        > /tmp/000_prerequisites_actual.sql
    sudo -u postgres psql -f /tmp/000_prerequisites_actual.sql
    rm /tmp/000_prerequisites_actual.sql
"
echo "    Prerequisites complete."

# ---------------------------------------------------------------------------
# Step 3: Run DDL files 001–006 as taxcollectorusr
# ---------------------------------------------------------------------------
DDL_FILES=(
    "001_ctl_schema.sql"
    "002_ref_schema.sql"
    "003_ref_seed.sql"
    "004_landing_schema.sql"
    "005_core_schema.sql"
    "006_mart_views.sql"
)

for DDL_FILE in "${DDL_FILES[@]}"; do
    echo ""
    echo ">>> Running $DDL_FILE..."
    ssh "$SSH_USER@$SERVER_HOST" \
        "PGPASSWORD=$TC_DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f $SERVER_DDL_PATH/$DDL_FILE"
done

# ---------------------------------------------------------------------------
# Step 4: Run smoke test
# ---------------------------------------------------------------------------
echo ""
echo ">>> Step 4: Running smoke test..."
ssh "$SSH_USER@$SERVER_HOST" \
    "PGPASSWORD=$TC_DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f $SERVER_DDL_PATH/999_smoke_test.sql"

# ---------------------------------------------------------------------------
# Step 5: Clean up temp files on server
# ---------------------------------------------------------------------------
ssh "$SSH_USER@$SERVER_HOST" "rm -rf $SERVER_DDL_PATH"
echo ""
echo "=== Provisioning complete. Check smoke test output above for FAIL messages. ==="
