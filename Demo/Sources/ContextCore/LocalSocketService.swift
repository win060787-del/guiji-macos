import Darwin
import Foundation

/// Private local JSON-line interface. No HTTP listener, LAN port, or shell execution.
public final class LocalSocketService: @unchecked Sendable {
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var lease: Int32 = -1
  private var clients: Set<Int32> = []
  private var working: Set<Int32> = []
  private var generation = UUID()
  public let url: URL
  private let broker: LocalGrantBroker
  public init(url: URL, broker: LocalGrantBroker) {
    self.url = url
    self.broker = broker
  }
  deinit { stop() }
  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard listener < 0 else { return }
    guard url.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw GrantError.invalidRequest
    }
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { throw GrantError.denied }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    let lockPath = parent.appendingPathComponent("service.lock").path
    let lease = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lease >= 0 else { throw GrantError.denied }
    guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(lease)
      throw GrantError.busy
    }
    var committed = false
    defer {
      if !committed {
        flock(lease, LOCK_UN)
        Darwin.close(lease)
      }
    }
    if FileManager.default.fileExists(atPath: url.path) {
      let info = try FileManager.default.attributesOfItem(atPath: url.path)
      guard info[.type] as? FileAttributeType == .typeSocket,
        (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
      else { throw GrantError.denied }
      guard unlink(url.path) == 0 else { throw GrantError.busy }
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GrantError.busy }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(url.path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      Darwin.close(fd)
      throw GrantError.busy
    }
    guard chmod(url.path, 0o600) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
      Darwin.listen(fd, 4) == 0
    else {
      Darwin.close(fd)
      unlink(url.path)
      throw GrantError.busy
    }
    self.lease = lease
    committed = true
    listener = fd
    generation = UUID()
    let epoch = generation
    DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop(fd, epoch: epoch) }
  }
  public func stop() {
    lock.lock()
    let fd = listener
    listener = -1
    generation = UUID()
    let clients = self.clients
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
      unlink(url.path)
    }
    // Workers retain ownership of close(); shutdown unblocks reads without descriptor reuse races.
    for client in clients { shutdown(client, SHUT_RDWR) }
    if lease >= 0 {
      flock(lease, LOCK_UN)
      Darwin.close(lease)
      lease = -1
    }
    lock.unlock()
  }
  private func acceptLoop(_ fd: Int32, epoch: UUID) {
    while true {
      lock.lock()
      guard listener == fd, generation == epoch else {
        lock.unlock()
        return
      }
      // Nonblocking accept and stop share the lock, avoiding descriptor-reuse races on restart.
      let client = Darwin.accept(fd, nil, nil)
      let code = errno
      if client < 0 {
        lock.unlock()
        guard code == EAGAIN || code == EWOULDBLOCK || code == EINTR else { return }
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = Darwin.poll(&event, 1, 100)
        continue
      }
      guard working.count < 4, clients.count < 8 else {
        lock.unlock()
        Darwin.close(client)
        continue
      }
      _ = fcntl(client, F_SETFL, 0)
      clients.insert(client)
      working.insert(client)
      lock.unlock()
      DispatchQueue.global(qos: .utility).async { [weak self] in self?.read(client, epoch: epoch) }
    }
  }
  private func read(_ fd: Int32, epoch: UUID) {
    defer {
      lock.lock()
      clients.remove(fd)
      working.remove(fd)
      Darwin.close(fd)
      lock.unlock()
    }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    let deadline = Date().addingTimeInterval(5)
    while data.count <= 4096, Date() < deadline {
      let count = Darwin.recv(fd, &buffer, buffer.count, 0)
      guard count > 0 else { return }
      data.append(contentsOf: buffer.prefix(count))
      if let newline = data.firstIndex(of: 10) {
        guard newline == data.count - 1, newline <= 4096 else { return }
        data.removeLast()
        lock.lock()
        let valid = generation == epoch && listener >= 0
        lock.unlock()
        guard valid else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let response = SocketReply()
        let request = data
        Task {
          response.set(await broker.handle(request))
          semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 20) == .success, let reply = response.get() else {
          return
        }
        lock.lock()
        let stillValid = generation == epoch && listener >= 0
        // The broker has finished. Release its admission slot before the response reaches
        // a client that may immediately reconnect; retain the descriptor for stop/cleanup.
        working.remove(fd)
        lock.unlock()
        guard stillValid else { return }
        var output = reply
        output.append(10)
        output.withUnsafeBytes { bytes in
          var sent = 0
          while sent < bytes.count {
            let count = Darwin.send(
              fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            guard count > 0 else { return }
            sent += count
          }
        }
        return
      }
    }
  }
}
private final class SocketReply: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func set(_ data: Data) {
    lock.lock()
    self.data = data
    lock.unlock()
  }
  func get() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
