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
    asking.snapshot.inputs[0].question?.binding = "unbound"; asking.snapshot.inputs[0].question?.workRef = nil; asking.snapshot.inputs[0].question?.workPhase = nil
    precondition(WorkResultPortfolio.groups([asking])[0].inputs.isEmpty, "unbound native inputs stay in the session, not guessed into a work card")
    var unlinked = session; unlinked.snapshot.codeProgress = nil; unlinked.snapshot.governance = nil
    precondition(WorkResultPortfolio.groups([unlinked]).isEmpty, "names/cwd/Todo do not invent work")
    var bad = progress; bad.observations[0].nextAction = "execute"; precondition(!bad.valid)
    bad = progress; bad.observations[0].binding.headSha = nil; precondition(!bad.valid)
    bad = progress; bad.observations[0].repository = "https://github.com/example/project"; precondition(!bad.valid && bad.observations[0].pullRequestURL == nil)
    print("Work card checks passed: independent progress/result lanes, exact sources/heads/bindings, newer unknown, earlier acceptance, stale coverage, declared input only and canonical PR links.")
  }
}
