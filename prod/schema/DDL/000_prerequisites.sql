-- =============================================================================
-- 000_prerequisites.sql
-- Run ONCE as the PostgreSQL superuser (postgres) before any other DDL.
-- DO NOT commit the actual password. Set TC_DB_PASSWORD on the server.
--
-- From the Ubuntu server:
--   export TC_DB_PASSWORD=Fletcher00
--   sudo -u postgres psql -f /path/to/000_prerequisites.sql
-- =============================================================================

-- Create database (skip if already exists)
SELECT 'CREATE DATABASE taxcollectordb'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'taxcollectordb')\gexec

-- Create user (skip if already exists)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'taxcollectorusr') THEN
        CREATE USER taxcollectorusr WITH PASSWORD 'REPLACE_WITH_TC_DB_PASSWORD';
        RAISE NOTICE 'User taxcollectorusr created.';
    ELSE
        RAISE NOTICE 'User taxcollectorusr already exists — skipping.';
    END IF;
END
$$;

-- Connect to taxcollectordb to create schemas and grant privileges
\c taxcollectordb

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Schemas
CREATE SCHEMA IF NOT EXISTS ctl AUTHORIZATION taxcollectorusr;
CREATE SCHEMA IF NOT EXISTS ref AUTHORIZATION taxcollectorusr;
CREATE SCHEMA IF NOT EXISTS landing AUTHORIZATION taxcollectorusr;
CREATE SCHEMA IF NOT EXISTS core AUTHORIZATION taxcollectorusr;
CREATE SCHEMA IF NOT EXISTS mart AUTHORIZATION taxcollectorusr;

-- Default privileges — any future tables created get auto-granted
ALTER DEFAULT PRIVILEGES IN SCHEMA ctl, ref, landing, core, mart
    GRANT ALL PRIVILEGES ON TABLES TO taxcollectorusr;
ALTER DEFAULT PRIVILEGES IN SCHEMA ctl, ref, landing, core, mart
    GRANT ALL PRIVILEGES ON SEQUENCES TO taxcollectorusr;

-- Explicit grants on schemas
GRANT USAGE, CREATE ON SCHEMA ctl, ref, landing, core, mart TO taxcollectorusr;

\echo '✓ Prerequisites complete. Run 001–006 DDL files next as taxcollectorusr.'
