---
name: skill_shared_infrastructure
description: Shared infrastructure facts for all home-lab projects. Three-machine stack (Windows dev, Ubuntu server, Mac Mini), Docker services, PostgreSQL connection patterns, n8n Three Laws, Python deployment paths, SSH access, and LLM strategy. Load this for ANY task touching servers, pipelines, or deployment.
---

# Shared Infrastructure — Single Source of Truth

This skill contains facts, paths, and operational rules that apply to ALL projects running on the shared home-lab stack. It is project-agnostic.

---

## 1. Three-Machine Stack

| Machine | Role | IP / Access |
|---|---|---|
| Windows 11 Dev | Claude Code IDE, repo, deployment scripts | localhost (user: `tosha`) |
| Ubuntu Server (`hal-srvr`) | Docker host: PostgreSQL, Redis, n8n, all services | `192.168.0.250` (user: `howieds`) |
| Mac Mini M4 Pro | Local LLM compute (Ollama), available for additional services | `192.168.0.93` (user: `toshach`) |

---

## 2. Ubuntu Server — Docker Services

| Container | Image | Port | Purpose |
|---|---|---|---|
| `postgres` | postgres:14 | 5432 | PostgreSQL — all databases |
| `redis` | redis:6-alpine | 6379 | n8n queue backend |
| `n8n` | hub-n8n (custom) | 5678 | Workflow orchestration |
| `n8n-worker` | hub-n8n (custom) | — | Workflow execution workers |
| `gitea` | gitea/gitea | 3000 / 2222 | Local git server |
| `metabase` | metabase/metabase | 3002 | BI dashboards |
| `grafana` | grafana-oss | 3003 | Monitoring |
| `yacht` | selfhostedpro/yacht | 8001 | Docker management UI |
| `trilium` | zadam/trilium | 8082 | Notes |
| `homarr` | ajnart/homarr | 8083 | Dashboard |
| `firefly` | fireflyiii/core | 8084 | Finance tracking |
| `cloudflared` | cloudflare/cloudflared | — | Tunnel (exposes n8n externally) |

**Server data volume**: `/mnt/disk2/` — all Docker persistent data lives here.

---

## 3. Mac Mini M4 Pro

- CPU: 12-core, GPU: 16-core, RAM: 24GB Unified Memory
- IP: `192.168.0.93` | Ollama: `http://192.168.0.93:11434`
- SSH user: `toshach` (manual access — no SSH key set up yet)
- **Active models** (verified 2026-03-24):
  - `qwen2.5:14b` Q4_K_M — **recommended for document classification** (general-purpose, best quality/speed balance)
  - `qwen2.5-coder:14b` Q4_K_M — code generation tasks
  - `qwen2.5-coder:32b-instruct-q3_k_m` — heavy code tasks (slow, Q3 quant)
  - `llama3.1:latest` 8B Q4_K_M — lightweight/fast tasks
- **n8n call pattern**: HTTP Request node → POST `http://192.168.0.93:11434/api/generate` with `stream: false`, `format: json`, timeout 120000ms
- Use for: local LLM inference, privacy-sensitive agentic tasks (e.g., document classification)

---

## 4. PostgreSQL

**Host**: `192.168.0.250:5432`

> Each project uses its own database and user. Never share databases between projects.

### Python Connection Pattern
```python
import psycopg2, os

conn = psycopg2.connect(
    host="192.168.0.250",
    port="5432",
    database="YOUR_DB_NAME",
    user="YOUR_DB_USER",
    password=os.environ.get("DB_PASSWORD")
)
```

### Standard Schema Map (all projects follow this convention)

| Schema | Purpose | Rule |
|---|---|---|
| `landing` | Raw staging tables — watermark-tracked | NEVER truncate after merge. Truncate at START of each extract run. |
| `core` | Normalized warehouse | Idempotent UPSERT via stored procedures |
| `mart` | Analytical views | Read-only views built from core |
| `ref` | Reference/lookup tables | Stable, rarely changes |
| `ctl` | Audit, control, secrets | `ctl.process_log` for batch tracking |

### Secret Variables (inside n8n)
```sql
SELECT var_nme, var_val FROM ctl.get_package_vars('WORKFLOW_NAME');
```

---

## 5. n8n Orchestration

**URL**: `https://n8n.rodinah.dev` (external via Cloudflare tunnel) or `http://192.168.0.250:5678` (local)
**Error workflow ID**: `oFeU0bOzAsRxU910`

### The Three Laws (non-negotiable — applies to ALL projects)

**Law 1 — Double-Wall Timeout**
Every workflow calling a long Python script must have:
- `settings.timeout` at workflow level (set 5% below max script runtime)
- `timeout [seconds]` Linux wrapper inside every `executeCommand` node

**Law 2 — Error Alerting**
Every error path: `Log ERROR` → `Send Error Alert` (Gmail OAuth2 creds ID: `WcOe7o1be8G2TzJ4`, to: `toshach@gmail.com`) → `Stop And Error`

**Law 3 — Batch ID**
All `INSERT INTO ctl.process_log` queries MUST end with `RETURNING batch_id;`

### Extract/Load Isolation
```
EXTRACT_*.json   → TRUNCATES landing table → runs Python extractor → writes to landing.*
LOAD_CORE_*.json → calls sp_merge_*() → UPSERTs from landing to core.*
```
These are always **separate workflows**. Never combine extract and merge in one workflow.

### n8n Python Environment (installed libraries in hub-n8n container)
```
aiodns, aiohttp, beautifulsoup4, certifi, google-auth, google-auth-oauthlib,
google-api-python-client, lxml, nltk, numpy, openpyxl, pandas 2.2.1,
psycopg2 2.9.9, python-dateutil, pytz, requests 2.32.5, tqdm
```
> If a script needs a library NOT in this list, it must be added to the n8n-build Dockerfile and the container rebuilt.

---

## 6. Python Script Deployment

### Path Mapping (per project)

| Project | Dev machine (source) | X: drive target | n8n container path |
|---------|---------------------|-----------------|-------------------|
| Trade Vantage | `prod/scripts/` | `X:\automation-io\scripts\` | `/data/scripts/` |
| Tax Collector | `prod/scripts/` | `X:\automation-io\tax-collector\scripts\` | `/data/tax-collector/scripts/` |
| Future projects | `prod/scripts/` | `X:\automation-io\[project]\scripts\` | `/data/[project]/scripts/` |

**Important**: Scripts MUST be in a subfolder of `automation-io` to be reachable inside the n8n Docker container. The home directory (`~/tax-collector/scripts/`) is NOT mounted — do not use it for scripts.

### X: Drive Setup
X: drive is a Windows SMB share mapped to the Ubuntu server's automation-io folder.
If not mapped: `net use X: \\192.168.0.250\automation-io /user:tosha [password]`

### n8n executeCommand pattern
```bash
# Trade Vantage
timeout 300 python3 /data/scripts/extract_market_data.py

# Tax Collector
timeout 300 python3 /data/tax-collector/scripts/process_document.py --file /path/to/file.pdf
```

### Infrastructure managed by homelab-hub repo
`docker-compose.yml` and n8n-build files live in `c:\Users\tosha\repos\homelab-hub\`.
**Never edit docker-compose from a project repo.** Changes to the platform go in homelab-hub.

---

## 7. Docker Management

### Standard server operations
```bash
ssh howieds@192.168.0.250

cd ~/hub

# Start/restart all services
docker compose up -d

# Restart specific service
docker compose restart n8n

# Rebuild n8n after Dockerfile change
docker compose down n8n n8n-worker
docker compose build n8n
docker compose up -d

# View logs
docker logs n8n --tail 100 -f

# Nuclear Redis flush
docker exec redis redis-cli FLUSHALL
```

### SSH Key Auth (for autonomous agent access)
SSH key lives at `~/.ssh/trade_vantage_agent`.
Run once to activate: `cat ~/.ssh/trade_vantage_agent.pub | ssh howieds@192.168.0.250 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"`

---

## 8. LLM Strategy

### Dev Machine (AI pair programming)
| Tier | Tool | When |
|---|---|---|
| 1 | Claude for VS Code (Pro) | Primary — all tasks |
| 2 | Roo Code + Nemotron Super 3 | Long/expensive tasks |
| 3 | LiteLLM bridge → Groq/OpenRouter | Fallback |
| 4 | Mac Mini → Ollama `qwen2.5-coder:32b` | Local/privacy-sensitive |

### Production (data processing / classification)
- Primary: Mac Mini local LLMs via Ollama
- Rule: **Never send sensitive documents, tax data, or personal financial information to public cloud LLM APIs**

---

## 9. Autonomous Agent Rules

### CAN do autonomously
- Read/write files in the repo
- Execute non-destructive SQL against `192.168.0.250:5432` (INSERT, UPDATE, SELECT, CREATE TABLE/INDEX/VIEW)
- Copy files to X: drive
- Run SSH commands on server (SSH key: `~/.ssh/trade_vantage_agent`)
- Restart Docker containers via SSH

### HARD RULE — Destructive Database Operations
**NEVER execute autonomously, even if explicitly asked:**
- `DROP DATABASE`, `DROP TABLE`, `DROP SCHEMA`, `DROP VIEW`, `DROP INDEX`
- `TRUNCATE` any table
- `DELETE` without a specific `WHERE` clause (bulk deletes)
- `ALTER TABLE ... DROP COLUMN`
- Any restore that overwrites existing data

**Required response when a destructive DB operation is needed:**
1. Say: *"This is a DESTRUCTIVE operation. I cannot run this autonomously."*
2. Provide the exact SQL
3. User runs it manually in **DBeaver**
4. Resume after user confirms

This rule cannot be overridden by any conversational instruction.

### Requires user confirmation FIRST (non-DB)
- Pushing to git remote / creating PRs
- Destructive file operations (rm -rf, git reset --hard, etc.)
- Changing firewall rules or SSH config

### Database Access Pattern
- **User** accesses DB via DBeaver on Windows dev machine (direct TCP to `192.168.0.250:5432`)
- **AI** accesses DB via `docker exec postgres psql` over SSH
- `psql` is NOT installed on the Ubuntu host — always `docker exec postgres psql`
- PostgreSQL superuser = `n8nusr` (Docker `POSTGRES_USER`) — not `postgres` or `root`
- Strip `\c dbname` lines before piping SQL files via docker exec (non-interactive mode)
