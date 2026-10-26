import Foundation
import PiDeskCore

private final class FakeNotifications: NotificationClient {
  var permission: AppNotificationAuthorization = .notDetermined
  var requestResult: Result<Bool, Error> = .success(false)
  var requested = 0
  var posts = 0
  var deliveryError: Error?
  var holdRequest = false
  var requestCompletion: ((Result<Bool, Error>) -> Void)?
  func settings(_ completion: @escaping (AppNotificationAuthorization) -> Void) { completion(permission) }
  func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void) {
    requested += 1
    if holdRequest { requestCompletion = completion } else { completion(requestResult) }
  }
  func post(id: String, title: String, body: String, completion: @escaping (Error?) -> Void) {
    precondition(title == "Pi 需要输入" && !body.contains("PRIVATE"))
    posts += 1; completion(deliveryError)
  }
}
private final class FakeLedger: UsageLedgerClient {
  var calls = 0
  var range: UsageDateRange?
  var completion: ((UsageAggregate) -> Void)?
  var hold = false
  func refresh(range: UsageDateRange, completion: @escaping (UsageAggregate) -> Void) {
    calls += 1; self.range = range
    if hold { self.completion = completion } else { completion(.empty(range, preview: true)) }
  }
}

@main enum NarrowUXChecks {
  @MainActor static func spin(_ condition: () -> Bool) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    precondition(condition(), "bounded completion missing")
  }
  @MainActor static func main() async throws {
    let fake = FakeNotifications(), ledger = FakeLedger()
    let model = AppModel(notificationClient: fake, usageLedger: ledger)
    defer { model.stop() }
    await spin { model.notificationStatus.contains("尚未授权") }
    precondition(fake.requested == 0 && fake.posts == 0, "startup must not request OS consent")
    let requestsBefore = model.store.requests.count
    model.page = "Token"
    precondition(!model.managerIsVisible && model.usageRefreshInterval == 60, "no manager cannot retain the Token page's fast interest")
    let backgroundCalls = ledger.calls
    model.refreshUsageIfDue(now: Date().addingTimeInterval(6))
    precondition(ledger.calls == backgroundCalls, "hidden/minimized/closed does not query every five seconds")
    model.refreshUsageIfDue(now: Date().addingTimeInterval(61))
    precondition(ledger.calls == backgroundCalls + 1, "background keeps bounded spool indexing, not collection shutdown")
    model.setManagerVisibility(true)
    precondition(model.managerIsVisible && model.usageRefreshInterval == 5)
    model.refreshUsageIfDue(now: Date().addingTimeInterval(6))
    precondition(ledger.calls == backgroundCalls + 2)
    model.page = "会话"
    precondition(model.usageRefreshInterval == 30)
    model.setManagerVisibility(false)
    precondition(model.usageRefreshInterval == 60)
    model.page = "Token"
    precondition(model.usageRefreshInterval == 60, "retained page does not override actual window interest")
    fake.permission = .authorized; fake.requestResult = .success(true)
    model.enableNotifications()
    await spin { model.notificationStatus.contains("已授权") && !model.requestingNotifications }
    precondition(fake.requested == 1 && model.settings.notifications)
    fake.permission = .denied
    model.checkNotificationStatus()
    await spin { model.notificationStatus.contains("已拒绝") }
    fake.requestResult = .success(false)
    model.enableNotifications()
    await spin { model.notificationStatus.contains("未获授权") }
    fake.requestResult = .failure(AppNotificationError.requestFailed)
    model.enableNotifications()
    await spin { model.notificationStatus.contains("开启系统通知失败") }
    fake.holdRequest = true
    model.enableNotifications(); model.enableNotifications()
    precondition(fake.requested == 4 && model.requestingNotifications, "only one in-flight explicit request")
    fake.requestCompletion?(.failure(AppNotificationError.requestFailed))
    await spin { !model.requestingNotifications }
    let input = try JSONDecoder().decode(InputNotice.self, from: Data(#"{"id":"fixture-input","source":"fixture","kind":"input","startedAt":1000}"#.utf8))
    let identity = Identity(localHostId: "fixture", nativeSessionId: "session", runtimeEpoch: "epoch")
    fake.permission = .authorized; fake.deliveryError = AppNotificationError.deliveryFailed
    model.sendNotification(for: input, session: identity)
    await spin { model.notificationStatus.contains("发送失败") }
    precondition(fake.posts == 1 && model.store.requests.count == requestsBefore, "display failure cannot send execution actions")
    fake.permission = .denied
    model.sendNotification(for: input, session: identity)
    await spin { model.notificationStatus.contains("已拒绝") }
    precondition(fake.posts == 1 && model.store.requests.count == requestsBefore)
    model.usagePreset = .custom
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    let today = calendar.startOfDay(for: Date())
    model.usageCustomStart = today; model.usageCustomEnd = today
    model.refreshUsage()
    let previous = model.aggregate, previousCalls = ledger.calls
    model.usageCustomStart = calendar.date(byAdding: .day, value: 1, to: today)!
    model.refreshUsage()
    precondition(!model.customRangeIsValid && ledger.calls == previousCalls && model.aggregate == previous)
    precondition(model.actionNote.contains("未查询新范围"))
    // In-flight response from a previously valid range must not replace the result after fields become invalid.
    model.usageCustomStart = today; ledger.hold = true; model.refreshUsage()
    let inFlightRange = ledger.range!
    model.usageCustomEnd = calendar.date(byAdding: .day, value: -1, to: today)!
    model.refreshUsage()
    let heldCalls = ledger.calls
    ledger.completion?(.empty(inFlightRange))
    precondition(!model.usageLoading && model.aggregate == previous && ledger.calls == heldCalls)
    // Start/end are calendar dates: earlier clock time on the same day remains a valid day range.
    model.usageCustomStart = today.addingTimeInterval(12 * 3600); model.usageCustomEnd = today
    ledger.hold = false; model.refreshUsage()
    precondition(model.customRangeIsValid && ledger.calls == heldCalls + 1)
    print("Narrow UX checks passed: visible/background usage interest, explicit authorization only, authorized/denied/error/send-failure, duplicate request, invalid custom range and stale in-flight preservation.")
  }
}
