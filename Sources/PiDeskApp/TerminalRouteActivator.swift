import Foundation

enum TerminalRouteActivator {
  enum Error: Swift.Error { case unavailable, ambiguous, identityMismatch }

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
        if (count of matches) is not 1 then return "AMBIGUOUS"
        set selectedWindow to item 1 of item 1 of matches
        set selectedTab to item 2 of item 1 of matches
        try
          if miniaturized of selectedWindow then set miniaturized of selectedWindow to false
        end try
        set selected tab of selectedWindow to selectedTab
        set index of selectedWindow to 1
        set frontmost to true
        return "TARGET:" & targetTty
      end tell
    """#.replacingOccurrences(of: "TTY", with: escaped)
    let output = try await FiniteCommand.run("/usr/bin/osascript", ["-e", script])
    guard let result = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), result == "TARGET:\(ttyPath)" else {
      throw output.contains(Data("AMBIGUOUS".utf8)) ? Error.ambiguous : Error.identityMismatch
    }
    return result
  }
}
