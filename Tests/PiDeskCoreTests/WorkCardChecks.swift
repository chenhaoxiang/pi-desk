import Foundation
import PiDeskCore

enum WorkCardChecks {
  static func run(_ base: Snapshot, root: URL) throws {
    let progress = try JSONDecoder().decode(CodeProgressProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/code-progress-v1.json")))
    let governance = try JSONDecoder().decode(GovernanceProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/work-results-v1.json")))
    var question = try JSONDecoder().decode(InputNotice.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/question-link-v1.json")))
    precondition(progress.valid && progress.observations[0].pullRequestURL?.absoluteString == "https://github.com/example/project/pull/42")
    var snapshot = base; snapshot.governance = governance; snapshot.codeProgress = progress; snapshot.inputs = []
    var store = SessionStore(); let connection = UUID()
    let wire = WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot)
    let decoded = try Wire.decode(Data(Wire.encode(wire).dropLast()))
    precondition(decoded.snapshot?.codeProgress == progress)
    precondition(store.apply(wire, connection: connection, now: snapshot.observedAt))
    let session = store.sessions[snapshot.identity.sessionKey]!
    let group = WorkResultPortfolio.groups([session])[0], stages = WorkCardPresentation.stages(group)
    precondition(stages.count == 4 && group.handoffs.count == 1)
    precondition(WorkCardPresentation.displayTitle(group) == "example/project #42", "only explicit unique PR targets improve readability; no invented task title")
    precondition(stages.first?.id.binding.headSha == String(repeating: "b", count: 40), "recent original head remains visible, without merging older heads")
    let source = stages.first { $0.id.binding.runId == "run-b" }!
    precondition(source.latestProgress?.progress.seq == 2 && source.phaseTitle == "阶段待核")
    precondition(source.historicalProgress.count == 1 && source.waitTitle.contains("不可用"))
    precondition(source.latestResult?.result.outcome == "unknown" && !source.resultTitle.contains("已交付"))
    precondition(stages.filter { $0.id.binding.headSha != nil }.count == 2, "different heads/runs are not one overall state")
    let successor = stages.first { $0.id.binding.runId == "run-c" }!
    precondition(successor.nextTitle.contains("对账") && successor.nextTitle.contains("尚未重新核验") && source.nextTitle == "核对原始来源")
    precondition(!Presentation.needsInput(session) && group.inputs.isEmpty, "CI/owner-gate/reconcile cannot become human input")
    precondition(!WorkCardPresentation.needsUserInput(group), "a work card without a declared native input is not an attention item")
    var other = session; other.snapshot.identity.nativeSessionId = "different-reporter"
    let mixed = WorkResultPortfolio.groups([session,other])
    precondition(mixed.count == 1 && WorkCardPresentation.stages(mixed[0]).count == 8)
    var differentPR = session
    var anotherPR = progress.observations[0]; anotherPR.pullRequest = 43; anotherPR.seq = 4; anotherPR.observedAt += 3
    differentPR.snapshot.codeProgress?.observations.append(anotherPR); differentPR.snapshot.codeProgress?.seq = 4
    let prStages = WorkCardPresentation.stages(WorkResultPortfolio.groups([differentPR])[0]).filter { $0.id.binding.runId == "run-b" }
    precondition(prStages.count == 3 && prStages.filter { $0.latestProgress != nil }.count == 2 && prStages.filter { $0.latestResult != nil }.count == 1, "ambiguous PR targets do not acquire an inferred result link")
    precondition(prStages.first(where: { $0.latestResult != nil })?.latestProgress == nil)
    let ambiguousTitle = WorkCardPresentation.displayTitle(WorkResultPortfolio.groups([differentPR])[0])
    precondition(!ambiguousTitle.contains("#42") && !ambiguousTitle.contains("#43"), "multiple original PRs cannot select a guessed work title")
    var noPR = group; noPR.progress = []
    precondition(WorkCardPresentation.displayTitle(noPR).hasPrefix(group.id.kindTitle))
    var conflict = session
    var newer = governance.results[0]; newer.seq = 5; newer.observedAt += 10
    newer.observation.decision = "reconcile_required"; newer.observation.outcome = "unknown"; newer.observation.reasonCode = "owner_outcome_unknown"
    conflict.snapshot.governance?.results.append(newer); conflict.snapshot.governance?.observerSeq = 5
    let artifact = WorkCardPresentation.stages(WorkResultPortfolio.groups([conflict])[0]).first { $0.id.binding.runId == "run-a" }!
    precondition(artifact.latestResult?.sequence == 5 && artifact.resultTitle.contains("结果待核") && artifact.historicalResults.count == 1, "older accepted must not outrank newer unknown on the same full binding")
    var oldAccepted = session
    oldAccepted.snapshot.governance?.results[1].observation.decision = "deliverable"
    oldAccepted.snapshot.governance?.results[1].observation.outcome = "accepted"
    oldAccepted.snapshot.governance?.results[1].observation.reasonCode = "owner_acceptance_confirmed"
    let historical = WorkCardPresentation.stages(WorkResultPortfolio.groups([oldAccepted])[0]).first { $0.id.binding.runId == "run-b" }!
    precondition(historical.phaseTitle == "阶段待核" && historical.resultIsEarlier && historical.resultTitle.hasPrefix("较早记录"))
    var stale = session; stale.snapshot.codeProgress?.coverage = "unavailable"; stale.snapshot.codeProgress?.seq += 1
    precondition(stale.snapshot.valid)
    let lastKnown = WorkCardPresentation.stages(WorkResultPortfolio.groups([stale])[0]).first { $0.latestProgress != nil }!
    precondition(lastKnown.latestProgress?.connected == false && lastKnown.phaseTitle.hasPrefix("进度待核"))
    question.question?.workRef = progress.observations[0].binding.workRef
    var asking = session; asking.snapshot.inputs = [question]
    precondition(asking.snapshot.valid && WorkResultPortfolio.groups([asking])[0].inputs.count == 1 && WorkCardPresentation.needsUserInput(WorkResultPortfolio.groups([asking])[0]) && Presentation.needsInput(asking))
    let brief = WorkObservationBrief(groups: WorkResultPortfolio.groups([asking]), sessions: [asking])
    precondition(brief.nativeInputCount == 1 && brief.inputLinkedWorkCount == 1 && brief.observedWorkCount == 1)
    let briefText = brief.text(now: Date(timeIntervalSince1970: question.startedAt / 1000 + 120))
    precondition(brief.oldestInputTitle(now: Date(timeIntervalSince1970: question.startedAt / 1000 + 120)).contains("2分钟"))
    precondition(briefText.contains("不是全天履历") && briefText.contains("head") && briefText.contains("原观察") && briefText.contains("来源"))
    let repeated = WorkObservationBrief(groups: mixed, sessions: [session, other])
    precondition(repeated.observedWorkCount == 1 && repeated.reportingSourceCount == 2 && repeated.nativeInputCount == 0, "work refs may group, independent reporter scope is not whole-business completion")
    var resultOnly = session; resultOnly.snapshot.codeProgress = nil
    let freshText = WorkObservationBrief(groups: WorkResultPortfolio.groups([resultOnly]), sessions: [resultOnly]).text(now: Date(timeIntervalSince1970: 1_730_000_000))
    resultOnly.snapshot.governance?.stale = true
    let staleText = WorkObservationBrief(groups: WorkResultPortfolio.groups([resultOnly]), sessions: [resultOnly]).text(now: Date(timeIntervalSince1970: 1_730_000_000))
    precondition(freshText != staleText && staleText.contains("结果来源非实时"), "copied result-only summary must preserve source-stale qualification")
    var decisionOnly = session; decisionOnly.snapshot.codeProgress = nil; decisionOnly.snapshot.governance = nil
    decisionOnly.snapshot.missionDecisions = try JSONDecoder().decode(MissionDecisionsProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/mission-decisions-v1.json")))
    let decisionText = WorkObservationBrief(groups: WorkResultPortfolio.groups([decisionOnly]), sessions: [decisionOnly]).text()
    precondition(decisionText.contains("原决策来源") && decisionText.contains(String(decisionOnly.snapshot.identity.nativeSessionId.suffix(8))) && decisionText.contains("原观察"), "decision-only records keep reporter and original observation")
    var offline = asking; offline.connection = .disconnected
    let offlineBrief = WorkObservationBrief(groups: WorkResultPortfolio.groups([offline]), sessions: [offline])
    precondition(offlineBrief.nativeInputCount == 0 && offlineBrief.oldestInputAt == nil)
    var unknownStart = asking; unknownStart.snapshot.inputs[0].startedAt = -1
    let unknownStartBrief = WorkObservationBrief(groups: [], sessions: [unknownStart])
    precondition(unknownStartBrief.nativeInputCount == 1 && unknownStartBrief.oldestInputTitle().contains("起点未提供"))
    let emptyBrief = WorkObservationBrief(groups: [], sessions: [])
    precondition(emptyBrief.text().contains("尚无可关联工作原件") && emptyBrief.oldestInputTitle().contains("未观察到"))
    asking.snapshot.inputs[0].question?.binding = "unbound"; asking.snapshot.inputs[0].question?.workRef = nil; asking.snapshot.inputs[0].question?.workPhase = nil
    precondition(WorkResultPortfolio.groups([asking])[0].inputs.isEmpty, "unbound native inputs stay in the session, not guessed into a work card")
    let unboundBrief = WorkObservationBrief(groups: WorkResultPortfolio.groups([asking]), sessions: [asking])
    precondition(unboundBrief.nativeInputCount == 1 && unboundBrief.inputLinkedWorkCount == 0, "input totals are not inferred work associations")
    var unlinked = session; unlinked.snapshot.codeProgress = nil; unlinked.snapshot.governance = nil
    precondition(WorkResultPortfolio.groups([unlinked]).isEmpty, "names/cwd/Todo do not invent work")
    var bad = progress; bad.observations[0].nextAction = "execute"; precondition(!bad.valid)
    bad = progress; bad.observations[0].binding.headSha = nil; precondition(!bad.valid)
    bad = progress; bad.observations[0].repository = "https://github.com/example/project"; precondition(!bad.valid && bad.observations[0].pullRequestURL == nil)
    print("Work card checks passed: independent progress/result lanes, exact sources/heads/bindings, newer unknown, earlier acceptance, stale coverage, declared input only and canonical PR links.")
  }
}
