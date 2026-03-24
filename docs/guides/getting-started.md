# Getting Started — Tax Collector

## Prerequisites
- Access to Ubuntu server at `192.168.0.250` (user: `howieds`)
- X: drive mapped to `\\192.168.0.250\automation-io`
- `TC_DB_PASSWORD` environment variable set (ask user for value)
- Gmail OAuth2 credentials (to be configured — see spec when written)

## First Steps
1. **Read the context**: Open `CONTEXT.md` — it shows current project state
2. **Start a task**: Use `/new-task` slash command
3. **Check specs**: Look in `specs/features/` for what's planned
4. **Infrastructure facts**: See `.agent/skills/skill_shared_infrastructure/SKILL.md`
5. **Project facts**: See `.agent/skills/skill_tax_collector_core/SKILL.md`

## Creating the Database (pending first spec)
```bash
# SSH to server
ssh howieds@192.168.0.250

# Create DB and user (run as postgres superuser inside container)
docker exec -it postgres psql -U postgres -c "CREATE DATABASE taxcollectordb;"
docker exec -it postgres psql -U postgres -c "CREATE USER taxcollectorusr WITH PASSWORD '[secret]';"
docker exec -it postgres psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE taxcollectordb TO taxcollectorusr;"
```
