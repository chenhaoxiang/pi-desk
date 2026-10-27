import AppKit
import ApplicationServices
import Foundation

enum TerminalRouteActivator {
  enum Error: Swift.Error { case unavailable, noMatch, ambiguous, identityMismatch }
  private static let queue = DispatchQueue(label: "pi-desk.terminal-permission", qos: .utility)
  static func permissionStatus(requestConsent: Bool = false) async -> String {
    await withCheckedContinuation { continuation in
      queue.async {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, requestConsent)
        switch status {
        case noErr: continuation.resume(returning: "终端Automation已授权")
        case OSStatus(-1744): continuation.resume(returning: "终端Automation尚未授权；主动定位时由系统询问，需用户决定")
        case OSStatus(-1743): continuation.resume(returning: "终端Automation已拒绝；请由用户在系统设置检查权限")
        default: continuation.resume(returning: "终端Automation状态不可用（\(status)）；未发起系统弹窗")
        }
      }
    }
  }
  static func focus(ttyPath: String) async throws -> String {
    guard ttyPath.range(of: "^/dev/(ttys[A-Za-z0-9]+|pts/[0-9]+)$", options: .regularExpression) != nil else { throw Error.unavailable }
    let escaped = ttyPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = #"""
      set targetTty to "TTY"
      tell application "Terminal"
        set matches to {}
        repeat with targetWindow in windows
          repeat with targetTab in tabs of targetWindow
            try
              if (tty of targetTab) is targetTty then set end of matches to {targetWindow, targetTab}
            end try
          end repeat
        end repeat
        if (count of matches) is 0 then return "NO_MATCH"
        if (count of matches) is not 1 then return "AMBIGUOUS"
        set selectedWindow to item 1 of item 1 of matches
        set selectedTab to item 2 of item 1 of matches
        try
          if miniaturized of selectedWindow then set miniaturized of selectedWindow to false
        end try
        set selected tab of selectedWindow to selectedTab
        set index of selectedWindow to 1
        activate
        if (tty of selected tab of front window) is not targetTty then return "MISMATCH"
        return "TARGET:" & targetTty
      end tell
    """#.replacingOccurrences(of: "TTY", with: escaped)
    let output = try await FiniteCommand.run("/usr/bin/osascript", ["-e", script])
    let result = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if result == "NO_MATCH" { throw Error.noMatch }
    if result == "AMBIGUOUS" { throw Error.ambiguous }
    guard result == "TARGET:\(ttyPath)" else { throw Error.identityMismatch }
    return result!
  }
}
