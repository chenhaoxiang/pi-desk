import Foundation
import UserNotifications

public enum AppNotificationAuthorization: Equatable {
  case authorized
  case provisional
  case ephemeral
  case denied
  case notDetermined
  case unknown
}

public enum AppNotificationError: Error, Equatable {
  case requestFailed
  case deliveryFailed
}

protocol NotificationClient: AnyObject {
  func settings(_ completion: @escaping (AppNotificationAuthorization) -> Void)
  func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void)
  func post(id: String, title: String, body: String, completion: @escaping (Error?) -> Void)
}

final class SystemNotificationClient: NotificationClient {
  private let center = UNUserNotificationCenter.current()

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
      if let error { completion(.failure(error)) }
      else { completion(.success(granted)) }
    }
  }

  func post(id: String, title: String, body: String, completion: @escaping (Error?) -> Void) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil), withCompletionHandler: completion)
  }
}
