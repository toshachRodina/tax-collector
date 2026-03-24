# Spec DDR Cheat Sheet

Quick reference for using the spec-kit in this project.

## When to Write a Spec
- Any new feature that touches more than 1 file
- Any pipeline, extractor, or workflow
- Any schema design

## Spec Flow
1. `specs/features/NNN-feature-name.md` — feature spec (WHAT)
2. `specs/features/NNN-feature-name-plan.md` — implementation plan (HOW)
3. `specs/features/NNN-feature-name-tasks.md` — task list (WHEN/WHO)

## Status Labels
- **Draft** → being written
- **Review** → ready for user review
- **Approved** → implementation can begin
- **Implemented** → done and in prod
- **Deprecated** → no longer relevant

## Constitutional Gates (check before writing a plan)
- Article VII: Start with ≤3 services
- Article VIII: Use framework features directly — no unnecessary wrappers
- Article IX: Prefer real DB over mocks in tests
