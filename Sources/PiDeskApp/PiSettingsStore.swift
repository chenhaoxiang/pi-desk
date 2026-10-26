import CryptoKit
import Darwin
import Foundation

struct PiSettingField: Identifiable {
  let key: String
  let title: String
  let choices: [String]
  let note: String
  var id: String { key }
  static let fields: [PiSettingField] = [
    .init(key: "theme", title: "终端主题", choices: ["system", "dark", "light"], note: "下次会话生效；自定义主题原值保留"),
    .init(key: "defaultThinkingLevel", title: "默认思考档", choices: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], note: "下次会话默认值；不改当前会话或模型专属覆盖"),
    .init(key: "steeringMode", title: "纠偏递送", choices: ["all", "one-at-a-time"], note: "下次会话生效"),
    .init(key: "followUpMode", title: "追加递送", choices: ["all", "one-at-a-time"], note: "下次会话生效"),
    .init(key: "compaction.enabled", title: "自动整理上下文", choices: ["true", "false"], note: "下次会话生效；不强制整理或重载"),
    .init(key: "retry.enabled", title: "自动重试", choices: ["true", "false"], note: "下次会话生效；不改变当前执行"),
    .init(key: "quietStartup", title: "安静启动", choices: ["false", "header", "true"], note: "下次启动生效"),
    .init(key: "tuiMode", title: "终端模式", choices: ["regular", "fullscreen"], note: "下次启动生效"),
    .init(key: "terminal.showImages", title: "终端显示图片", choices: ["true", "false"], note: "下次会话生效；不改模型图片能力"),
    .init(key: "terminal.showTerminalProgress", title: "终端进度提示", choices: ["true", "false"], note: "下次会话生效")
  ]
}
struct PiSettingsRevision: Equatable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let mtimeSeconds: Int64
  let mtimeNanoseconds: Int64
  let sha256: String
}
struct PiSettingsSnapshot {
  let path: String
  let revision: PiSettingsRevision
  let values: [String: String]
  let projectValues: [String: String]
  let projectPath: String?
  let projectIssue: String?
  let projectCwd: String?
}
enum PiSettingsFailure: String, Error {
  case unavailable = "原Pi设置不可读；未创建影子配置"
  case unsafe = "设置权限/路径不安全；仅保留现状"
  case invalidJSON = "原Pi设置不是有效JSON对象；未覆盖原文件"
  case locked = "Pi设置正在被其他写入者占用；请稍后刷新"
  case conflict = "原Pi设置在编辑后已变化；请刷新后重新编辑"
  case invalidChange = "设置值不在本次白名单中；未写入"
  case writeFailed = "设置保存失败；原文件与备份已保留，请刷新核对"
}

/// Exact native user settings.json, never a merged or SQLite settings mirror.
final class PiSettingsStore {
  static let unset = "__default__"
  private let queue = DispatchQueue(label: "io.github.chenhaoxiang.pi-desk.pi-settings", qos: .utility)
  let agentDir: URL
  let backupDir: URL
  init(agentDir: URL? = nil, backupDir: URL? = nil) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    self.agentDir = agentDir ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"] ?? home.appendingPathComponent(".pi/agent").path)
    self.backupDir = backupDir ?? home.appendingPathComponent("Library/Application Support/PiDesk/pi-settings-backups")
  }
  func load(projectCwd: String?, completion: @escaping (Result<PiSettingsSnapshot, PiSettingsFailure>) -> Void) {
    queue.async {
      let result = Result { try self.readSnapshot(projectCwd: projectCwd) }.mapError { ($0 as? PiSettingsFailure) ?? .unavailable }
      DispatchQueue.main.async { completion(result) }
    }
  }
  func save(changes: [String: String], expected: PiSettingsSnapshot, completion: @escaping (Result<PiSettingsSnapshot, PiSettingsFailure>) -> Void) {
    queue.async {
      let result = Result { try self.write(changes: changes, expected: expected) }.mapError { ($0 as? PiSettingsFailure) ?? .writeFailed }
      DispatchQueue.main.async { completion(result) }
    }
  }
  private var path: URL { agentDir.appendingPathComponent("settings.json") }
  private func checkedRead(_ url: URL) throws -> (Data, PiSettingsRevision, mode_t) {
    guard url.path.hasPrefix("/"), url.standardized.path == url.path else { throw PiSettingsFailure.unsafe }
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw PiSettingsFailure.unavailable }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
      info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 1_048_576 else { throw PiSettingsFailure.unsafe }
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), readCount = 0
    while readCount < bytes.count {
      let remaining = bytes.count - readCount
      let n = bytes.withUnsafeMutableBytes { buffer in Darwin.read(fd, buffer.baseAddress!.advanced(by: readCount), remaining) }
      guard n > 0 else { throw PiSettingsFailure.unavailable }; readCount += n
    }
    let data = Data(bytes)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let revision = PiSettingsRevision(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size, mtimeSeconds: Int64(info.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec), sha256: hash)
    return (data, revision, info.st_mode & 0o777)
  }
  private func parse(_ data: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else { throw PiSettingsFailure.invalidJSON }
    return dictionary
  }
  private func get(_ object: [String: Any], key: String) -> Any? {
    let parts = key.split(separator: ".").map(String.init)
    guard let first = parts.first else { return nil }
    if parts.count == 1 { return object[first] }
    return (object[first] as? [String: Any])?[parts[1]]
  }
  private func projection(_ object: [String: Any]) -> [String: String] {
    var values: [String: String] = [:]
    for field in PiSettingField.fields {
      if let value = get(object, key: field.key) {
        if let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() { values[field.key] = boolean.boolValue ? "true" : "false" }
        else if let text = value as? String, text.utf8.count <= 128 { values[field.key] = text }
        else { values[field.key] = "__invalid__" }
      }
    }
    return values
  }
  private func readSnapshot(projectCwd: String?) throws -> PiSettingsSnapshot {
    let (data, revision, _) = try checkedRead(path)
    let values = projection(try parse(data))
    var overlay: [String: String] = [:], projectPath: String?, projectIssue: String?
    if let projectCwd, projectCwd.hasPrefix("/") {
      let url = URL(fileURLWithPath: projectCwd).appendingPathComponent(".pi/settings.json")
      if FileManager.default.fileExists(atPath: url.path) {
        projectPath = url.path
        do {
          let (bytes, _, _) = try checkedRead(url)
          overlay = projection(try parse(bytes))
        } catch let error { projectIssue = (error as? PiSettingsFailure)?.rawValue ?? "项目settings.json来源未知；用户层未修改" }
      }
    }
    return PiSettingsSnapshot(path: path.path, revision: revision, values: values, projectValues: overlay, projectPath: projectPath, projectIssue: projectIssue, projectCwd: projectCwd)
  }
  private func write(changes: [String: String], expected: PiSettingsSnapshot) throws -> PiSettingsSnapshot {
    guard expected.path == path.path, !changes.isEmpty else { throw PiSettingsFailure.invalidChange }
    let fields = Dictionary(uniqueKeysWithValues: PiSettingField.fields.map { ($0.key, $0) })
    for (key, value) in changes { guard let field = fields[key], value == Self.unset || field.choices.contains(value) else { throw PiSettingsFailure.invalidChange } }
    let lock = path.path + ".lock"
    // Native proper-lockfile uses atomic mkdir(path+'.lock', realpath:false).
    // Never remove stale/unknown locks, and keep this transaction well below its 10s stale age.
    guard mkdir(lock, 0o700) == 0 else { throw PiSettingsFailure.locked }
    var lockInfo = stat()
    guard lstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFDIR, lockInfo.st_uid == getuid() else { throw PiSettingsFailure.unsafe }
    defer {
      var current = stat()
      if lstat(lock, &current) == 0, current.st_ino == lockInfo.st_ino, current.st_dev == lockInfo.st_dev { _ = rmdir(lock) }
    }
    let started = ProcessInfo.processInfo.systemUptime
    let (original, revision, mode) = try checkedRead(path)
    guard revision == expected.revision else { throw PiSettingsFailure.conflict }
    var object = try parse(original)
    for (key, value) in changes {
      let parts = key.split(separator: ".").map(String.init)
      let typed: Any?
      if value == Self.unset { typed = nil }
      else if value == "true" { typed = true }
      else if value == "false" { typed = false }
      else { typed = value }
      if parts.count == 1 { object[parts[0]] = typed }
      else {
        if let existing = object[parts[0]], !(existing is [String: Any]) { throw PiSettingsFailure.invalidChange }
        var nested = object[parts[0]] as? [String: Any] ?? [:]; nested[parts[1]] = typed; object[parts[0]] = nested
      }
    }
    let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    guard output.count <= 1_048_576 else { throw PiSettingsFailure.invalidChange }
    try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var backupInfo = stat()
    guard lstat(backupDir.path, &backupInfo) == 0, backupInfo.st_mode & S_IFMT == S_IFDIR, backupInfo.st_uid == getuid(), backupInfo.st_mode & 0o077 == 0 else { throw PiSettingsFailure.unsafe }
    let backup = backupDir.appendingPathComponent("settings-" + revision.sha256 + ".json")
    if !FileManager.default.fileExists(atPath: backup.path) { try privateWrite(original, to: backup, mode: 0o600, replace: false) }
    let (_, latest, _) = try checkedRead(path)
    guard latest == revision, ProcessInfo.processInfo.systemUptime - started < 2 else { throw PiSettingsFailure.conflict }
    try privateWrite(output, to: path, mode: mode, replace: true)
    return try readSnapshot(projectCwd: expected.projectCwd)
  }
  private func privateWrite(_ data: Data, to target: URL, mode: mode_t, replace: Bool) throws {
    let temporary = target.deletingLastPathComponent().appendingPathComponent(".pi-desk-settings-" + UUID().uuidString)
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
    guard fd >= 0 else { throw PiSettingsFailure.writeFailed }
    defer { Darwin.close(fd); _ = unlink(temporary.path) }
    var written = 0
    while written < data.count {
      let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: written), data.count - written) }
      guard n > 0 else { throw PiSettingsFailure.writeFailed }; written += n
    }
    guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw PiSettingsFailure.writeFailed }
    if !replace && FileManager.default.fileExists(atPath: target.path) { return }
    guard rename(temporary.path, target.path) == 0 else { throw PiSettingsFailure.writeFailed }
    let directory = open(target.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
    if directory >= 0 { _ = fsync(directory); Darwin.close(directory) }
  }
}
