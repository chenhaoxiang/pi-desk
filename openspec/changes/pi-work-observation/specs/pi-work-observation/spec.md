## ADDED Requirements

### Requirement: Pi-owned task observation
Pi Desk SHALL consume bounded native Todo result metadata only through the enrolled Pi runtime, keep it read-only and non-authorizing, and never create a parallel task database or infer product/work ownership from names or paths.

#### Scenario: Successful current-scope Todo snapshot
- **WHEN** Pi emits a successful Todo result whose start belongs to the current runtime and observation scope
- **THEN** Desk displays only the allowed task identifiers, titles, active form, original status, dependencies and owner labels with source and observation coverage

#### Scenario: Missing or old source
- **WHEN** no Todo snapshot has been observed or an older bridge does not provide it
- **THEN** the UI reports not-observed or unavailable, not zero tasks or completed work

### Requirement: Honest progress and attention
The work overview SHALL distinguish task records from verified outcomes, user-input lifecycle from dependency blocking, and derived UI guidance from original owner next actions.

#### Scenario: Plan completed but result not verified
- **WHEN** native Todo rows are marked completed without owner result evidence
- **THEN** Desk may show recorded completed task counts but SHALL NOT label the product delivered, verified or business complete

#### Scenario: Dependency waiting without human request
- **WHEN** a pending task has unresolved blockedBy references but Pi has no active input notice
- **THEN** it is shown as dependency waiting, not a request for the user to approve, answer or restart work

### Requirement: Scope and resource safety
Task projection SHALL remain bounded, protect raw/sensitive data, and invalidate old task scope after clear or branch/session replacement without modifying Pi execution.

#### Scenario: Late result after branch change
- **WHEN** a Todo call ends after its captured scope was invalidated
- **THEN** its rows cannot replace the new scope's projection and no action is replayed

#### Scenario: Oversized or sensitive task metadata
- **WHEN** projected rows exceed the text/count/frame budget or include recognized sensitive values
- **THEN** the observer bounds or redacts the projection, exposes partial/unavailable coverage, and leaves the original Todo result unchanged

### Requirement: Pi management boundary
Work-overview management actions SHALL use existing Pi public operations bound to exact runtime identity and reflect original receipts, without directly mutating Todo or owner state in Desk.

#### Scenario: Client unavailable or target replaced
- **WHEN** Desk is closed/disconnected or a user clicks an obsolete target
- **THEN** Pi execution continues independently and no action is redirected to a same-name replacement
