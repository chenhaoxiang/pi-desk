import CryptoKit
import Darwin
import Foundation

@main enum PiSettingsStoreChecks {
  @MainActor static func wait<T>(_ start: (@escaping (Result<T, PiSettingsFailure>) -> Void) -> Void) async -> Result<T, PiSettingsFailure> {
    await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
  }
  static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
  static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func write(_ text: String, _ url: URL, mode: mode_t = 0o600) throws { try Data(text.utf8).write(to: url); chmod(url.path, mode) }
  @MainActor static func main() async throws {
    let base = URL(fileURLWithPath: CommandLine.arguments[1]), agent = base.appendingPathComponent("agent"), backup = base.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = agent.appendingPathComponent("settings.json")
    try write("{\"defaultThinkingLevel\":\"medium\",\"unknownTop\":{\"keep\":42},\"compaction\":{\"enabled\":true,\"unknownNested\":\"keep\"}}\n", path)
    let store = PiSettingsStore(agentDir: agent, backupDir: backup)
    guard case .success(let snapshot) = await wait({ store.load(projectCwd: nil, completion: $0) }) else { fatalError("fixture settings load") }
    precondition(snapshot.values["defaultThinkingLevel"] == "medium")
    guard case .success(let updated) = await wait({ store.save(changes: ["theme": "dark"], expected: snapshot, completion: $0) }) else { fatalError("fixture settings save") }
    let object = try JSONSerialization.jsonObject(with: bytes(path)) as! [String: Any]
    precondition((object["unknownTop"] as? [String: Any])?["keep"] as? Int == 42)
    precondition((object["compaction"] as? [String: Any])?["unknownNested"] as? String == "keep")
    precondition(updated.values["theme"] == "dark")
    let backups = try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
    precondition(backups.count == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: backups[0].path)[.posixPermissions] as! NSNumber
    precondition(permissions.intValue & 0o077 == 0)
    try write("{bad", path)
    if case .failure(.invalidJSON) = await wait({ store.load(projectCwd: nil, completion: $0) }) {} else { fatalError("bad JSON must reject") }
    try write("{\"compaction\":\"wrong-type\",\"theme\":\"system\"}", path)
    guard case .success(let typeSnapshot) = await wait({ store.load(projectCwd: nil, completion: $0) }) else { fatalError("type fixture load") }
    let typeBefore = try sha(bytes(path))
    if case .failure(.invalidChange) = await wait({ store.save(changes: ["compaction.enabled": "false"], expected: typeSnapshot, completion: $0) }) {} else { fatalError("group type conflict must reject") }
    let typeAfter = try sha(bytes(path)); precondition(typeAfter == typeBefore)
    try write("{\"theme\":\"system\"}", path, mode: 0o644)
    if case .failure(.unsafe) = await wait({ store.load(projectCwd: nil, completion: $0) }) {} else { fatalError("broad permissions must reject") }
    chmod(path.path, 0o600)
    try FileManager.default.createDirectory(atPath: path.path + ".lock", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lockedBefore = try sha(bytes(path))
    guard case .success(let lockedSnapshot) = await wait({ store.load(projectCwd: nil, completion: $0) }) else { fatalError("locked fixture load") }
    if case .failure(.locked) = await wait({ store.save(changes: ["theme": "light"], expected: lockedSnapshot, completion: $0) }) {} else { fatalError("existing lock must reject") }
    let lockedAfter = try sha(bytes(path)); precondition(lockedAfter == lockedBefore)
    try FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + ".lock"))
    guard case .success(let revisionSnapshot) = await wait({ store.load(projectCwd: nil, completion: $0) }) else { fatalError("revision fixture load") }
    try write("{\"theme\":\"light\"}", path)
    let revisionBefore = try sha(bytes(path))
    if case .failure(.conflict) = await wait({ store.save(changes: ["theme": "dark"], expected: revisionSnapshot, completion: $0) }) {} else { fatalError("revision conflict must reject") }
    let revisionAfter = try sha(bytes(path)); precondition(revisionAfter == revisionBefore)
    print("Pi settings checks passed: whitelist projection, unknown preservation, bad/type/permission/lock/revision refusal, atomic backup and readback.")
  }
}
