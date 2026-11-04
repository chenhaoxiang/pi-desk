## ADDED Requirements

### Requirement: Exact notification navigation and interaction continuity
Pi Desk SHALL bind notification clicks to an exact enrolled runtime, retain unsent drafts on an unconfirmed quit, and expose read-only health plus a fixed-action command palette without invoking a model.

#### Scenario: Old runtime notification
- **WHEN** a clicked notification refers to a replaced runtime
- **THEN** no other session is opened as a substitute and no work is started or answered

#### Scenario: Quit with unsent drafts
- **WHEN** a normal quit/update is requested with unsent drafts
- **THEN** retaining the app and drafts is the default unless the user explicitly discards them

### Requirement: Local display and work organization
Pi Desk SHALL provide display modes, screen choice and bounded user work groups as local presentation preferences, never as execution or identity authorities.

#### Scenario: Menu only or unavailable display
- **WHEN** the user hides the top panel or its display disconnects
- **THEN** Pi work and collection continue and the normal menu remains available

### Requirement: Optional registered-model analysis
Pi Desk SHALL use the configured Pi registered model for explicit user analysis only, defaulting to codex-local-8319/gpt-6.1-sol at medium thinking, without modifying business model settings or creating a tool-enabled agent.

#### Scenario: Registered model selection without a new bridge
- **WHEN** local Pi SDK is installed but all enrolled sessions have older bridges
- **THEN** its registered model and supported thinking choices remain selectable without starting or reloading business Pi, and unsupported recent text stays explicitly unavailable

#### Scenario: Native session name
- **WHEN** Pi provides or changes a session /name
- **THEN** the AI source title uses that native name rather than a Desk alias or project hash, while the exact runtime remains its control identity

#### Scenario: Provider unavailable
- **WHEN** the selected model or thinking level is unavailable
- **THEN** analysis fails clearly without silent fallback, retry, or impact on business Pi

### Requirement: Bounded selected-context access
Pi Desk SHALL request only selected live runtimes current-branch recent user/assistant text for explicit AI use, with preview/removal and bounded traversal; credentials, thinking, tool bodies and historical discovery are excluded.

#### Scenario: Old bridge or sensitive text
- **WHEN** context is unsupported or a message contains a detected sensitive value
- **THEN** unsupported context remains unavailable and the affected text is not sent; manual metadata-only analysis remains possible

### Requirement: Non-authoritative AI results
Pi Desk SHALL label AI output as sourced analysis, validate input references and runtime freshness, retain truthful request states and separately report numeric AI usage without persisting transcript text.

#### Scenario: Result arrives after runtime change
- **WHEN** the input runtime has changed before a result is applied
- **THEN** the result cannot modify new runtime group membership or any execution state

#### Scenario: Cancellation or timeout
- **WHEN** an AI request is cancelled or its result is unknown
- **THEN** only that request is affected, no business abort is sent and no duplicate request is automatically dispatched
