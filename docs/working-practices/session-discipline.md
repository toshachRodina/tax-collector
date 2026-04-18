# Claude Code Session Discipline

> Goal: prevent context rot (hallucination, decision forgetting) and minimise token burn across all projects.

## What's Installed

- **`code-review-graph` MCP server** — global, auto-detects the current repo's graph. Reduces file reads by ~7× on average; auto-updates when you save files.
- **ADR table in each `CLAUDE.md`** — decisions persist across `/compact` and new sessions.
- **Hooks in `.claude/settings.json`** — graph auto-updates on Edit/Write/Bash; graph status shown on session start.

## The 90-Minute Rule

Context accuracy degrades measurably after ~40-50k tokens of conversation history (roughly 45-90 min of active work). The fix:

1. Work on **one coherent sub-task** per session.
2. When Claude Code shows context pressure (or ~90 min has passed): run `/compact`.
3. Start a new session — `CLAUDE.md` loads automatically; context graph is already indexed.
4. **Before closing for the day:** run `/handoff` to update `CONTEXT.md`.

## Session Start Template

Paste this (or a variation) at the start of each session:

```
Context: [2-3 sentences from CONTEXT.md "What's next" section]
Today's goal: [one sentence — e.g. "implement bank CSV extraction pipeline"]
```

Claude reads `CLAUDE.md` automatically — you don't need to re-explain architecture, database rules, or coding conventions.

## For New Repos

When you first start working in a repo that doesn't have a graph yet:

```bash
cd c:/Users/tosha/repos/<repo-name>
PYTHONUTF8=1 code-review-graph build
```

Takes 2-5 min. After that the graph auto-updates on file changes.

## Adding to the ADR Table

When you and Claude make an architectural decision, append a row:

```markdown
| 2026-MM-DD | Decision made | Why — what problem it solves, what was rejected |
```

This survives `/compact` and new sessions. Claude checks it before suggesting approaches.

## Verification

- Run `/mcp` in Claude Code — should show `code-review-graph` as connected
- Ask "what calls `sp_merge_tax_documents`?" in tax-collector — should answer without reading all files
- After `/compact`, open new session — Claude should reference ADRs from `CLAUDE.md`
