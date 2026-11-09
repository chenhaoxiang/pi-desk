import Foundation
import PiDeskCore

enum ActivityContinuityChecks {
  static func run(_ base: Snapshot) throws {
    let at=1_730_000_000_000.0, connection=UUID()
    var snapshot=base; snapshot.inputs=[]; snapshot.seq=1; snapshot.observedAt=at
    snapshot.activity=SessionActivity(sequence:3,kind:"agent-settled",at:at-60_000,turnEndedAt:at-60_000,turnEndSequence:3)
    var store=SessionStore()
    precondition(store.apply(WireRecord(kind:"hello",identity:snapshot.identity,snapshot:snapshot),connection:connection,now:at))
    func timing(_ ms:Double)->String { SessionExperience.timing(store.sessions[snapshot.identity.sessionKey]!,now:Date(timeIntervalSince1970:ms/1000)) }
    precondition(timing(at)=="最近活动 1分钟前")
    var missing=snapshot;missing.seq+=1;missing.observedAt+=240_000;missing.activity=nil
    precondition(store.apply(WireRecord(kind:"snapshot",identity:missing.identity,snapshot:missing),connection:connection,now:missing.observedAt))
    precondition(timing(at+240_000)=="最后已知活动 5分钟前", "a legal activity-less snapshot must not erase the observed event")
    let retained=store.sessions[snapshot.identity.sessionKey]!.lastObservedActivity
    precondition(retained?.at==at-60_000 && retained?.source==snapshot.identity)
    precondition(store.sessions[snapshot.identity.sessionKey]!.snapshot.activity==nil,"display cache must not patch the original snapshot or its unread turn identity")
    let encoded=try Wire.encode(WireRecord(kind:"snapshot",identity:missing.identity,snapshot:missing))
    precondition(!String(decoding:encoded,as:UTF8.self).contains("lastObservedActivity"),"no new wire or second data source")
    store.tick(now:at+300_000)
    precondition(timing(at+300_000)=="最后已知活动 6分钟前")
    let reconnected=UUID();missing.seq+=1;missing.observedAt+=1
    precondition(store.apply(WireRecord(kind:"hello",identity:missing.identity,snapshot:missing),connection:reconnected,now:missing.observedAt))
    precondition(store.sessions[snapshot.identity.sessionKey]!.lastObservedActivity==retained)
    var replacement=missing;replacement.identity.runtimeEpoch="new-activity-epoch";replacement.seq=1;replacement.observedAt+=1
    let newConnection=UUID()
    precondition(store.apply(WireRecord(kind:"hello",identity:replacement.identity,snapshot:replacement),connection:newConnection,now:replacement.observedAt))
    precondition(timing(at+300_000)=="上次运行活动 6分钟前")
    let current=store.sessions[snapshot.identity.sessionKey]!
    precondition(current.snapshot.activity==nil && current.lastObservedActivity?.source==snapshot.identity)
    precondition(SessionExperience.activityDetail(current).contains("当前运行尚未报告活动"))
    var noDisplayCopy=current;noDisplayCopy.lastObservedActivity=nil
    precondition(Presentation.executionState(current)==Presentation.executionState(noDisplayCopy) && Presentation.needsInput(current)==Presentation.needsInput(noDisplayCopy),"history must not change execution or input")
    var late=missing;late.seq+=10;late.observedAt+=100_000
    precondition(!store.apply(WireRecord(kind:"hello",identity:late.identity,snapshot:late),connection:UUID(),now:late.observedAt),"retired epoch cannot overwrite current source")
    replacement.seq+=1;replacement.observedAt+=1;replacement.activity=SessionActivity(sequence:1,kind:"agent-start",at:at+299_000)
    precondition(store.apply(WireRecord(kind:"snapshot",identity:replacement.identity,snapshot:replacement),connection:newConnection,now:replacement.observedAt))
    precondition(timing(at+300_000)=="刚有活动" && store.sessions[snapshot.identity.sessionKey]!.lastObservedActivity?.source==replacement.identity)
    store.disconnect(newConnection)
    precondition(timing(at+360_000)=="最后已知活动 1分钟前")
    var another=replacement;another.identity.nativeSessionId="other-activity-session";another.seq=1;another.activity=nil
    precondition(store.apply(WireRecord(kind:"hello",identity:another.identity,snapshot:another),connection:UUID(),now:another.observedAt))
    let other=store.sessions[another.identity.sessionKey]!
    precondition(other.lastObservedActivity==nil && SessionExperience.timing(other)=="尚未观察到活动","name/cwd cannot transfer activity between sessions")
    // A cached stamp supplied for an unrelated source is never displayed.
    var wrong=other;wrong.lastObservedActivity=retained
    precondition(SessionExperience.timing(wrong)=="尚未观察到活动")
    let future=SessionExperience.timing(current,now:Date(timeIntervalSince1970:(at-70_000)/1000))
    precondition(future=="活动时间待核")
    var bounded=SessionStore()
    precondition(bounded.apply(WireRecord(kind:"hello",identity:snapshot.identity,snapshot:snapshot),connection:connection,now:at))
    bounded.disconnect(connection)
    for index in 0..<64 {
      var newSession=another;newSession.identity.nativeSessionId="bounded-activity-\(index)";newSession.observedAt=at+Double(index)+1
      precondition(bounded.apply(WireRecord(kind:"hello",identity:newSession.identity,snapshot:newSession),connection:UUID(),now:newSession.observedAt))
    }
    precondition(bounded.sessions.count==64 && bounded.sessions[snapshot.identity.sessionKey]==nil)
    precondition(bounded.sessions.values.allSatisfy { $0.lastObservedActivity==nil },"evicted display copies have no unbounded side store")
    print("Activity continuity checks passed: original-time retention, reconnect/new-epoch display scope, no raw snapshot/wire/execution/input mutation, late rejection and source isolation")
  }
}
