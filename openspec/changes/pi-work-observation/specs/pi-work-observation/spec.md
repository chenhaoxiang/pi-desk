## ADDED Requirements

### Requirement: Independent original code progress
Desk SHALL consume the optional codeProgress v1 sidecar from the existing owner snapshot query/reply/changed port, with independent sequence/fingerprint and the original host/epoch fence. Progress SHALL NOT alter old result/handoff semantics, timestamps or acceptance, and work.refresh SHALL NOT perform network, file, model or owner-verification work.

#### Scenario: Progress changes without a result change
- **WHEN** a valid code progress update has a new progress sequence but the old outer sequence is unchanged
- **THEN** the progress view updates while the original result/handoff view and its timestamps remain unchanged; a legacy client continues to consume the old fields

#### Scenario: Unavailable or invalid optional progress
- **WHEN** progress is missing, malformed, conflicting, or reports unavailable with retained rows
- **THEN** only that lane is unknown/last-known; old rows keep their original times and cannot regain current status from a lower sequence, and valid original result data is not erased

### Requirement: Work summary preserves exact sources and scope
Existing work cards SHALL show only original work references, explicit PR/head, observed stage/wait source, stage-scoped acceptance, original next action and declared native input; missing metadata SHALL be explicit rather than inferred from names, directories, Todo counts or chat.

#### Scenario: Earlier acceptance and newer unknown
- **WHEN** one complete binding and reporter has both earlier accepted and newer unknown observations
- **THEN** the newer observation is its default summary, earlier observations remain expandable, and different heads/runs/revisions/reporters are not merged into overall completion

#### Scenario: Bounded original navigation
- **WHEN** an explicit public repository/pullRequest or original reporter route is available
- **THEN** the user may open that canonical PR or exact source session; opaque result references are not guessed into paths, commands or URLs, and no execution/approval button is added

#### Scenario: Human input remains native
- **WHEN** code checks, owner Gate or source evidence are missing or pending without a native input lifecycle
- **THEN** no human approval/request is created; only existing declared-work input notices may attach to the work card

### Requirement: Original transport relations without business inference
Desk SHALL consume only finalized successful native Intercom status results for the exact requested message in the current runtime scope. It SHALL NOT issue new queries, inspect message/history text, infer relationships from request text or UI closure, or turn transport messages into work items or human-input alerts.

#### Scenario: Replacement and an old reply arriving late
- **WHEN** original retained status records provide supersedes, supersededBy or lateReplyTo with explicit broker sender and recipient IDs
- **THEN** Desk displays those exact bounded IDs and original replyCorrelation independently per reporter; a late reply SHALL NOT mark the newer ask answered or business-approved

#### Scenario: Matched, none and unknown
- **WHEN** the original broker reports matched, none, unknown or no supported relation metadata
- **THEN** matched means only original transport reply matching, none does not mean business unanswered, and missing/unsupported metadata remains unavailable without guessing approval, applicability or revocation

#### Scenario: Scope, conflicts and bounds
- **WHEN** status results arrive late, conflict at the same original timestamp, exceed budgets or belong to an invalidated scope
- **THEN** older originals cannot replace a retained newer record, same-time conflicts stay unknown until a newer original, omissions remain explicit within the existing frame limit, and prior-scope calls cannot publish

### Requirement: Original mission decision status
Desk SHALL passively project only bounded identity, state and timestamps from successful original subagent mission management results, without reading decision text or answers, invoking mission queries, introducing a data authority, or deriving authorization and completion.

#### Scenario: Finalized original only
- **WHEN** a current-scope management tool_result matches the explicit mission identity and a successful finalized tool_execution_end matches its projected original
- **THEN** Desk may publish the decision metadata; an error, mismatch, missing or oversized source SHALL NOT become an empty or resolved record

#### Scenario: One decision resolved and another open
- **WHEN** the original record resolves A while B stays open
- **THEN** Desk displays the partial resolution, without creating a human-input request or claiming user approval, all answers received or task acceptance

#### Scenario: Fresh reporter reads the same original
- **WHEN** another Pi session naturally executes mission.show for the same explicit mission
- **THEN** Desk displays that successful original under its distinct reporting session; it neither scans the store nor transfers ownership or sums duplicate counts

#### Scenario: Old and conflicting originals
- **WHEN** an incoming original is older than a retained sourceUpdatedAt, or has the same timestamp with a different decision projection
- **THEN** the older original cannot overwrite the newer record, and equal-time conflicts remain unavailable until a strictly newer valid original arrives; observer order SHALL NOT substitute for a native revision

#### Scenario: Scope and display limits
- **WHEN** the session scope changes or records exceed the bounded window or wire budget
- **THEN** old scope calls cannot publish; current omissions and cumulative window evictions remain explicit and are not represented as a global unique work count, while the original tool and Pi execution remain unchanged

### Requirement: Original question work association
Desk SHALL retain existing input UI and consume only the original question owner’s content-free optional work association. A caller-declared work reference SHALL NOT be treated as authenticated ownership, an applied decision, execution authorization or business completion.

#### Scenario: Legacy and work-aware events describe the same question
- **WHEN** the owner emits pi:input-required v1 and pi:work-question:v1 for the same original native toolCallId
- **THEN** Desk keeps one input identity and one reminder, attaches only bounded workRef/stage metadata, and does not read question text, options or answers

#### Scenario: Missing or invalid association
- **WHEN** the owner reports unbound or unavailable work metadata
- **THEN** the original input remains usable with explicit coverage and no inferred product/work mapping or extra approval

#### Scenario: Answer received or input closed
- **WHEN** the original owner reports answer-received or closed
- **THEN** that input stops waiting without marking a decision applied, all questions answered, work complete or permission granted; legacy end remains functional if optional metadata fails

#### Scenario: Inapplicable linked event
- **WHEN** a work-question event has a wrong native session, retired owner epoch or non-increasing sequence
- **THEN** its association cannot overwrite current input metadata; Desk does not claim that epoch-less legacy events establish the missing provenance

#### Scenario: Original route and unread state
- **WHEN** work metadata arrives for an existing input or the user marks it read
- **THEN** its existing exact-runtime route and unread key stay stable, no second notification or answer request is sent


### Requirement: Native owner result consumption
Desk SHALL consume only the native Pi Vista owner’s bounded read-only export of already completed observations. Existing PiWorkBinding, PiResultConsumption and PiWorkHandoffObservation retain their original semantics and are not a second task database or acceptance authority.

#### Scenario: Read existing observations
- **WHEN** an exact enrolled runtime reads owner observation coverage or reconnects
- **THEN** the query reads only owner memory and SHALL NOT invoke an owner reader, perform IO or verification, scan history, run a model, or replay an operation

#### Scenario: Artifact and source acceptance are separate
- **WHEN** an owner reports deliverable for subagent-output-available or source-shared-delivery
- **THEN** Desk labels only that original stage and SHALL NOT infer business completion, installation, runtime loading, or acknowledgement

#### Scenario: Explicit grouping only
- **WHEN** multiple enrolled reporters provide the same explicit owner/kind/key
- **THEN** their observations may be grouped while full stage/run/session/revision/head bindings remain separate, and other tasks in those sessions are not implicitly attached

#### Scenario: Late observer scope or unavailable producer
- **WHEN** a reply belongs to an expired request/scope, a retired owner epoch, or a different host session
- **THEN** it cannot replace current observations; missing or unsupported producers remain unavailable/not-observed without fallback discovery

#### Scenario: Preserved handoff is not renewed proof
- **WHEN** a valid original handoff contains nextAction, blocker references and unresolved effects
- **THEN** those references stay readable with currentVerification=not_checked and authorization=none; wait/reconcile are not automatically human-input alerts

#### Scenario: Observation display exceeds frame budget
- **WHEN** owner observations exceed Desk row or byte budgets
- **THEN** complete observations are omitted with partial coverage and exact omission counts, without truncating identity or expanding the total wire limit


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
