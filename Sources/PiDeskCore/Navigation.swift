import Foundation

public enum NavigationError: Error { case unavailable, ambiguous, invalidResponse }
public struct HerdrPane: Equatable, Sendable {
  public let paneId: String
  public let workspaceId: String
  public let tabId: String
}
public enum Navigation {
  // Caller obtains a fresh owner snapshot. No cwd/name or stale pane fallback.
  public static func exactPane(snapshot: Data, sessionFile: String) throws -> HerdrPane {
    guard let raw = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
      throw NavigationError.invalidResponse
    }
    let result = raw["result"] as? [String: Any] ?? raw
    let envelope = result["snapshot"] as? [String: Any] ?? result
    guard let panes = envelope["panes"] as? [[String: Any]] else {
      throw NavigationError.invalidResponse
    }
    let matches = panes.filter { p in
      guard let s = p["agent_session"] as? [String: Any] else { return false }
      return s["source"] as? String == "herdr:pi" && s["kind"] as? String == "path"
        && s["value"] as? String == sessionFile
    }
    guard matches.count == 1, let p = matches.first, let id = p["pane_id"] as? String,
      let workspace = p["workspace_id"] as? String, let tab = p["tab_id"] as? String
    else { throw matches.isEmpty ? NavigationError.unavailable : NavigationError.ambiguous }
    return HerdrPane(paneId: id, workspaceId: workspace, tabId: tab)
  }
}
