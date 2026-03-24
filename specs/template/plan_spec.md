# Implementation Plan: [Feature Name]

## Specification Reference
[Link to or summary of the feature specification this plan implements]

## Constitutional Compliance Check
### Phase -1: Pre-Implementation Gates
#### Simplicity Gate (Article VII)
- [ ] Using ≤3 projects/services?
- [ ] No future-proofing without justification?

#### Anti-Abstraction Gate (Article VIII)
- [ ] Using framework features directly?
- [ ] Single model representation where appropriate?

#### Integration-First Gate (Article IX)
- [ ] Contracts defined and approved?
- [ ] Contract tests written and failing (Red phase)?

## Technical Architecture
### Technology Stack Choices
- Primary Language/Framework: [Choice and rationale]
- Database: [Choice and rationale for data storage]
- Communication: [API protocols, messaging systems]
- Third-party Services: [External dependencies and justification]

### Data Flow Architecture
[Description of how data moves through the system for this feature]
- Input → [Processing Step 1] → [Processing Step 2] → Output
- Include any transformations, enrichments, or validations

### Component Breakdown
- [Component 1]: [Responsibility and interface]
- [Component 2]: [Responsibility and interface]
- [Component 3]: [Responsibility and interface]

## Detailed Documentation
### Data Models
[Reference to data-model.md or inline schema definitions]

### API Contracts
[Reference to contracts/ directory or inline API specifications]

### Test Strategy
[Overview of testing approach - unit, integration, contract, end-to-end]

### Deployment Considerations
[Any special deployment, configuration, or infrastructure needs]

## Quickstart Guide
[Key validation scenarios that demonstrate the feature working]
- Scenario 1: [Simple case to verify basic functionality]
- Scenario 2: [Edge case to verify error handling]
- Scenario 3: [Performance case to verify scalability]

## Complexity Tracking
[Document any deviations from constitutional gates with justification]
- Deviation 1: [What was done differently and why it was necessary]
- Deviation 2: [Trade-offs considered and accepted]
