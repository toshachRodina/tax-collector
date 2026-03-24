# Trade Vantage Development Constitution

## Article I: Library-First Principle
Every feature MUST begin as a standalone library before integration into application code.
- No feature shall be implemented directly within application code
- First abstract into reusable library component with clear boundaries

## Article II: CLI Interface Mandate
All library interfaces MUST:
- Accept text input (stdin, arguments, files)
- Produce text output (stdout)
- Support JSON format for structured data exchange
- Be observable and testable through text-based interfaces

## Article III: Test-First Imperative
Implementation MUST follow strict Test-Driven Development:
1. Unit tests written and approved by user
2. Tests confirmed to FAIL (Red phase)
3. Only then generate implementation code
4. Tests must PASS (Green phase) before considering complete

## Article IV: Research-Driven Development
All specifications MUST include:
- Technical context gathering (library compatibility, performance)
- Organizational constraints (database standards, auth requirements)
- Deployment policy considerations
- Security implications analysis

## Article V: Bidirectional Feedback Loop
Production metrics and incidents MUST:
- Update specifications for next regeneration
- Transform into new non-functional requirements
- Become constraints affecting future generations

## Article VI: Branching for Exploration
Specifications MUST support:
- Multiple implementation approaches from same spec
- Exploration of different optimization targets (performance, maintainability, UX, cost)
- Easy pivoting when requirements change

## Article VII: Simplicity Gate
Initial implementation MUST:
- Use ≤3 projects/services
- Avoid future-proofing without documented justification
- Start simple, add complexity only when proven necessary

## Article VIII: Anti-Abstraction Gate
Development MUST:
- Use framework features directly rather than wrapping them
- Maintain single model representation where possible
- Justify every layer of complexity

## Article IX: Integration-First Testing
Tests MUST use realistic environments:
- Prefer real databases over mocks
- Use actual service instances over stubs
- Contract tests mandatory before implementation
- Validate in production-like conditions
