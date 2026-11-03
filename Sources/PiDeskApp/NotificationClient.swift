import Foundation
import PiDeskCore
import UserNotifications

public enum AppNotificationAuthorization: Equatable {
  case authorized, provisional, ephemeral, denied, notDetermined, unknown
}
public enum AppNotificationError: Error, Equatable { case requestFailed, deliveryFailed }

enum AppNotificationDiagnostic {
  static func detail(_ error: Error) -> String {
    let value = error as NSError
    guard [UNErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain].contains(value.domain) else { return "" }
    return "（\(value.domain):\(value.code)）"
  }
}
protocol NotificationClient: AnyObject {
  func settings(_ completion: @escaping (AppNotificationAuthorization) -> Void)
  func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void)
  func post(id: String, title: String, body: String, completion: @escaping (Error?) -> Void)
  func post(id: String, title: String, body: String, target: NotificationTarget?, completion: @escaping (Error?) -> Void)
  func onActivation(_ handler: @escaping (NotificationTarget) -> Void)
}
extension NotificationClient {
  func onActivation(_ handler: @escaping (NotificationTarget) -> Void) {}
  func post(id: String, title: String, body: String, target: NotificationTarget?, completion: @escaping (Error?) -> Void) {
    post(id: id, title: title, body: body, completion: completion)
  }
}
final class SystemNotificationClient: NSObject, NotificationClient, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let lock = NSLock()
  private var activate: ((NotificationTarget) -> Void)?

  func onActivation(_ handler: @escaping (NotificationTarget) -> Void) {
    lock.lock(); activate = handler; lock.unlock()
    center.delegate = self
  }
  func settings(_ completion: @escaping (AppNotificationAuthorization) -> Void) {
    center.getNotificationSettings { settings in
      let value: AppNotificationAuthorization
      switch settings.authorizationStatus {
      case .authorized: value = .authorized
      case .provisional: value = .provisional
      case .ephemeral: value = .ephemeral
      case .denied: value = .denied
      case .notDetermined: value = .notDetermined
      @unknown default: value = .unknown
      }
      completion(value)
    }
  }
  func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void) {
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
      if let error { completion(.failure(error)) } else { completion(.success(granted)) }
    }
  }
  func post(id: String, title: String, body: String, completion: @escaping (Error?) -> Void) {
    post(id: id, title: title, body: body, target: nil, completion: completion)
  }
  func post(id: String, title: String, body: String, target: NotificationTarget?, completion: @escaping (Error?) -> Void) {
    let content = UNMutableNotificationContent()
    content.title = title; content.body = body
    if let payload = target?.payload { content.userInfo = ["piDeskTarget": payload] }
    center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil), withCompletionHandler: completion)
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    defer { completionHandler() }
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let raw = response.notification.request.content.userInfo["piDeskTarget"] as? String,
      let target = NotificationTarget.decode(raw) else { return }
    lock.lock(); let handler = activate; lock.unlock()
    handler?(target)
  }
}
