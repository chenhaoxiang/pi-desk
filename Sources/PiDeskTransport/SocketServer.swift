import Darwin
import Foundation
import PiDeskCore

public enum SocketFailure: Error {
  case unsafePath, unsafeDirectory, unsafeSocket, alreadyRunning, systemCall
}
public final class SocketServer: @unchecked Sendable {
  public enum Event: Sendable {
    case record(WireRecord, UUID)
    case disconnected(UUID)
    case diagnostic(String)
  }
  private final class Client {
    let fd: Int32
    let id = UUID()
    let connectedAt = Date()
    var identity: Identity?
    var framer = LineFramer()
    var source: DispatchSourceRead?
    var output: [Data] = []
    var offset = 0
    init(_ fd: Int32) { self.fd = fd }
    var bytes: Int { output.reduce(0) { $0 + $1.count } - offset }
  }
  private let queue = DispatchQueue(label: "pi-desk.socket", qos: .utility)
  private var lockFD: Int32 = -1
  private var listener: Int32 = -1
  private var source: DispatchSourceRead?
  private var timer: DispatchSourceTimer?
  private var clients: [UUID: Client] = [:]
  private var inode: ino_t?
  private var stopped = true
  private var latest: [UUID: WireRecord] = [:]
  private var replies: [(WireRecord, UUID)] = []
  private var deliveryScheduled = false
  private var announced = Set<UUID>()
  private var closed = Set<UUID>()
  private var pendingDiagnostic: String?
  private let handler: @Sendable (Event) -> Void
  public let path: String
  public init(path: String, handler: @escaping @Sendable (Event) -> Void) {
    self.path = path
    self.handler = handler
  }
  public func start() {
    queue.async {
      do { try self.listen() } catch { self.handler(.diagnostic("socket-start-failed")) }
    }
  }
  public func stop() { queue.sync { self.shutdown() } }
  deinit { if listener >= 0 { Darwin.close(listener) } }
  public func send(_ record: WireRecord, to id: UUID) {
    queue.async {
      guard let c = self.clients[id], c.identity == record.identity else { return }
      do {
        let data = try Wire.encode(record)
        guard c.output.count < 32, c.bytes + data.count <= 1_048_576 else {
          self.closeClient(id)
          return
        }
        c.output.append(data)
        self.flush(c)
      } catch { self.closeClient(id) }
    }
  }
  public func close(_ id: UUID) { queue.async { self.closeClient(id) } }
  private func checkedDirectory() throws {
    guard path.hasPrefix("/"), path.utf8.count <= 103,
      URL(fileURLWithPath: path).standardized.path == path
    else { throw SocketFailure.unsafePath }
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let components = directory.split(separator: "/")
    var current = ""
    for (index, part) in components.enumerated() {
      current += "/" + part
      var info = stat()
      if lstat(current, &info) != 0 {
        guard errno == ENOENT, mkdir(current, 0o700) == 0 else {
          throw SocketFailure.unsafeDirectory
        }
        guard lstat(current, &info) == 0 else { throw SocketFailure.unsafeDirectory }
      }
      guard (info.st_mode & S_IFMT) == S_IFDIR else { throw SocketFailure.unsafeDirectory }
      if index == components.count - 1 {
        guard info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
          throw SocketFailure.unsafeDirectory
        }
      }
    }
  }
  private func address() throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw SocketFailure.unsafePath
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
    return addr
  }
  private func connectTest(_ addr: inout sockaddr_un) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return true }
    defer { Darwin.close(fd) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    let result = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return result == 0 || errno != ECONNREFUSED
  }
  private func listen() throws {
    guard stopped else { return }
    try checkedDirectory()
    var addr = try address()
    var old = stat()
    let lockPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(
      "receiver.lock"
    ).path
    let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw SocketFailure.unsafeDirectory }
    var lockInfo = stat()
    guard fstat(lock, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
      lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1, (lockInfo.st_mode & 0o077) == 0
    else {
      Darwin.close(lock)
      throw SocketFailure.unsafeDirectory
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(lock)
      throw SocketFailure.alreadyRunning
    }
    var admitted = false
    defer { if !admitted { Darwin.close(lock) } }
    if lstat(path, &old) == 0 {
      guard (old.st_mode & S_IFMT) == S_IFSOCK, old.st_uid == getuid(), (old.st_mode & 0o077) == 0
      else { throw SocketFailure.unsafeSocket }
      guard !connectTest(&addr) else { throw SocketFailure.alreadyRunning }
      var check = stat()
      guard lstat(path, &check) == 0, check.st_ino == old.st_ino, unlink(path) == 0 else {
        throw SocketFailure.unsafeSocket
      }
    } else if errno != ENOENT {
      throw SocketFailure.unsafeSocket
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketFailure.systemCall }
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
      Darwin.close(fd)
      throw SocketFailure.systemCall
    }
    let result = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw SocketFailure.systemCall
    }
    guard chmod(path, 0o600) == 0, Darwin.listen(fd, 32) == 0 else {
      Darwin.close(fd)
      throw SocketFailure.systemCall
    }
    var info = stat()
    guard lstat(path, &info) == 0 else {
      Darwin.close(fd)
      throw SocketFailure.systemCall
    }
    inode = info.st_ino
    listener = fd
    lockFD = lock
    admitted = true
    stopped = false
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    self.source = source
    source.setEventHandler { [weak self] in self?.acceptClients() }
    source.resume()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    self.timer = timer
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      for c in Array(self.clients.values) {
        if c.identity == nil && Date().timeIntervalSince(c.connectedAt) > 5 {
          self.closeClient(c.id)
        } else {
          self.flush(c)
        }
      }
    }
    timer.resume()
    handler(.diagnostic("socket-ready"))
  }
  private func acceptClients() {
    for _ in 0..<16 {
      let fd = Darwin.accept(listener, nil, nil)
      if fd < 0 { return }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard clients.count < 64, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
        fcntl(fd, F_SETFL, O_NONBLOCK) == 0
      else {
        Darwin.close(fd)
        continue
      }
      var yes: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
      let c = Client(fd)
      clients[c.id] = c
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      c.source = source
      source.setEventHandler { [weak self, weak c] in if let c = c { self?.read(c) } }
      source.resume()
    }
  }
  private func read(_ c: Client) {
    var bytes = [UInt8](repeating: 0, count: 8192)
    for _ in 0..<4 {
      let n = Darwin.read(c.fd, &bytes, bytes.count)
      if n == 0 {
        closeClient(c.id)
        return
      }
      if n < 0 {
        if errno != EAGAIN && errno != EWOULDBLOCK { closeClient(c.id) }
        return
      }
      do {
        for record in try c.framer.append(Data(bytes.prefix(n))) {
          if c.identity == nil {
            guard record.kind == "hello" else {
              closeClient(c.id)
              return
            }
            c.identity = record.identity
          }
          guard c.identity == record.identity,
            ["hello", "snapshot", "action-result", "operation-update"].contains(record.kind)
          else {
            closeClient(c.id)
            return
          }
          if record.kind == "hello" || record.kind == "snapshot" {
            var latestRecord = record
            if latest[c.id]?.kind == "hello" { latestRecord.kind = "hello" }
            latest[c.id] = latestRecord
          } else {
            guard replies.count < 128 else {
              closeClient(c.id)
              return
            }
            replies.append((record, c.id))
          }
          scheduleDelivery()
        }
      } catch {
        pendingDiagnostic = "invalid-peer-frame"
        scheduleDelivery()
        closeClient(c.id)
        return
      }
    }
  }
  private func scheduleDelivery() {
    guard !deliveryScheduled else { return }
    deliveryScheduled = true
    queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard let self = self else { return }
      let states = self.latest
      let replies = self.replies
      let closed = self.closed
      self.closed.removeAll(keepingCapacity: true)
      let diagnostic = self.pendingDiagnostic
      self.pendingDiagnostic = nil
      self.announced.formUnion(states.keys)
      self.latest.removeAll(keepingCapacity: true)
      self.replies.removeAll(keepingCapacity: true)
      // At most one immutable batch can wait on the UI thread. New snapshots
      // remain coalesced on the socket queue while that batch is pending.
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        for (id, record) in states { self.handler(.record(record, id)) }
        for (record, id) in replies { self.handler(.record(record, id)) }
        for id in closed { self.handler(.disconnected(id)) }
        if let code = diagnostic { self.handler(.diagnostic(code)) }
        self.queue.async {
          self.deliveryScheduled = false
          if !self.latest.isEmpty || !self.replies.isEmpty || !self.closed.isEmpty
            || self.pendingDiagnostic != nil
          {
            self.scheduleDelivery()
          }
        }
      }
    }
  }
  private func flush(_ c: Client) {
    for _ in 0..<8 {
      guard !c.output.isEmpty else { return }
      let data = c.output[0]
      let sent = data.withUnsafeBytes { b in
        Darwin.write(c.fd, b.baseAddress!.advanced(by: c.offset), data.count - c.offset)
      }
      if sent < 0 {
        if errno != EAGAIN && errno != EWOULDBLOCK { closeClient(c.id) }
        return
      }
      guard sent > 0 else { return }
      c.offset += sent
      if c.offset == data.count {
        c.output.removeFirst()
        c.offset = 0
      }
    }
  }
  private func closeClient(_ id: UUID) {
    guard let c = clients.removeValue(forKey: id) else { return }
    c.source?.cancel()
    c.source = nil
    Darwin.close(c.fd)
    latest.removeValue(forKey: id)
    replies.removeAll { $0.1 == id }
    if announced.remove(id) != nil {
      closed.insert(id)
      scheduleDelivery()
    }
  }
  private func shutdown() {
    guard !stopped else { return }
    stopped = true
    source?.cancel()
    source = nil
    timer?.cancel()
    timer = nil
    for id in Array(clients.keys) { closeClient(id) }
    if listener >= 0 {
      Darwin.close(listener)
      listener = -1
    }
    var info = stat()
    if lstat(path, &info) == 0, info.st_uid == getuid(), info.st_ino == inode,
      (info.st_mode & S_IFMT) == S_IFSOCK
    {
      _ = unlink(path)
    }
    inode = nil
    if lockFD >= 0 {
      Darwin.close(lockFD)
      lockFD = -1
    }
    latest.removeAll()
    replies.removeAll()
  }
}
