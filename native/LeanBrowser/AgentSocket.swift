import Darwin
import Foundation

final class AgentSocket {
    typealias Handler = ([String: Any], @escaping ([String: Any]) -> Void) -> Void

    private let handler: Handler
    private let ioQueue = DispatchQueue(label: "dev.leanbrowser.agent-socket", qos: .utility, attributes: .concurrent)
    private let listenerQueue = DispatchQueue(label: "dev.leanbrowser.agent-socket.listener", qos: .utility)
    private let lock = NSLock()
    private let clients = DispatchSemaphore(value: 4)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    let socketPath: String

    init(handler: @escaping Handler) {
        self.handler = handler
        socketPath = ProcessInfo.processInfo.environment["LEANBROWSER_SOCKET_PATH"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".leanbrowser/native.sock")
    }

    deinit { stop() }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == -1 else { return }

        guard socketPath.hasPrefix("/"), !socketPath.utf8.contains(0) else {
            throw ProtocolError.invalid("socket path must be an absolute path")
        }
        try prepareSocketDirectory()
        try removeOwnedStaleSocket()

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("create socket") }
        guard configureListener(fd) else { Darwin.close(fd); throw socketError("configure socket") }
        do {
            var address = try unixAddress()
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw socketError("bind socket") }
            guard Darwin.chmod(socketPath, 0o600) == 0 else { throw socketError("set socket permissions") }
            guard Darwin.listen(fd, 4) == 0 else { throw socketError("listen") }
        } catch {
            Darwin.close(fd)
            try? removeOwnedStaleSocket()
            throw error
        }

        listener = fd
        var socketStatus = stat()
        guard Darwin.lstat(socketPath, &socketStatus) == 0 else {
            Darwin.close(fd)
            listener = -1
            try? removeOwnedStaleSocket()
            throw socketError("inspect socket")
        }
        let event = DispatchSource.makeReadSource(fileDescriptor: fd, queue: listenerQueue)
        event.setEventHandler { [weak self] in self?.acceptClients() }
        let path = socketPath
        let socketInode = socketStatus.st_ino
        event.setCancelHandler {
            Darwin.close(fd)
            AgentSocket.unlinkOwnedSocket(path, inode: socketInode)
        }
        source = event
        event.resume()
    }

    func stop() {
        lock.lock()
        let oldSource = source
        source = nil
        listener = -1
        lock.unlock()
        oldSource?.cancel()
    }

    private func acceptClients() {
        lock.lock()
        let listenerFD = listener
        lock.unlock()
        guard listenerFD >= 0 else { return }
        while true {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            guard clients.wait(timeout: .now()) == .success else { Darwin.close(fd); continue }
            let clientSlots = clients
            ioQueue.async { [weak self, clientSlots] in
                guard let self else { Darwin.close(fd); clientSlots.signal(); return }
                self.serve(fd)
            }
        }
    }

    private func serve(_ fd: Int32) {
        let client = Client(fd: fd, ioQueue: ioQueue) { [clients] in clients.signal() }
        guard configureClient(fd), sameUser(fd), let line = readLine(fd: fd, limit: 64 * 1024) else { client.close(); return }
        let request: [String: Any]
        do {
            let json = try JSONSerialization.jsonObject(with: line, options: [])
            guard let object = json as? [String: Any] else { throw ProtocolError.invalid("request must be an object") }
            request = object
        } catch {
            client.reply(["id": NSNull(), "ok": false, "error": "malformed JSON request"])
            return
        }
        guard let id = request["id"] as? String, !id.isEmpty,
              let operation = request["operation"] as? String, !operation.isEmpty,
              request["arguments"] is [String: Any] else {
            client.reply(["id": request["id"] as? String ?? NSNull(), "ok": false,
                          "error": "request requires string id, string operation, and object arguments"])
            return
        }

        let timeout = DispatchWorkItem {
            client.reply(["id": id, "ok": false, "error": "outcome_unknown: operation timed out; do not retry mutations"])
        }
        ioQueue.asyncAfter(deadline: .now() + 30, execute: timeout)
        DispatchQueue.main.async { [weak self] in
            guard let self else { client.close(); return }
            self.handler(request) { reply in
                timeout.cancel()
                var normalized = reply
                normalized["id"] = id
                normalized["ok"] = (reply["ok"] as? Bool) ?? false
                if normalized["ok"] as? Bool == false, normalized["error"] == nil { normalized["error"] = "operation failed" }
                client.reply(normalized)
            }
        }
    }

    private func prepareSocketDirectory() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        var st = stat()
        if Darwin.lstat(directory, &st) != 0 {
            guard errno == ENOENT, Darwin.mkdir(directory, 0o700) == 0 else { throw socketError("create socket directory") }
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else {
            throw ProtocolError.invalid("unsafe socket directory")
        }
    }

    private func removeOwnedStaleSocket() throws {
        var st = stat()
        guard Darwin.lstat(socketPath, &st) == 0 else {
            guard errno == ENOENT else { throw socketError("inspect socket") }
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { throw ProtocolError.invalid("unsafe existing socket") }
        if connectProbe() { throw ProtocolError.invalid("LeanBrowser agent socket is already active") }
        guard Darwin.unlink(socketPath) == 0 else { throw socketError("remove stale socket") }
    }

    private func connectProbe() -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        guard let address = try? unixAddress() else { return false }
        var copy = address
        let result = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&descriptor, 1, 200) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }

    private func unixAddress() throws -> sockaddr_un {
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw ProtocolError.invalid("socket path too long") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        bytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        return address
    }

    private func configureListener(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func configureClient(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    private func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    private func readLine(fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(5)
        while data.count < limit {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, Int32(ceil(remaining * 1_000))) > 0 else { return nil }
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else { return nil }
            if byte == 10 { return data }
            data.append(byte)
        }
        return nil
    }

    private func socketError(_ operation: String) -> Error { NSError(domain: "LeanBrowser.AgentSocket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not \(operation): \(String(cString: strerror(errno)))"]) }

    private static func unlinkOwnedSocket(_ path: String, inode: ino_t) {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFSOCK,
              st.st_uid == getuid(),
              st.st_ino == inode else { return }
        Darwin.unlink(path)
    }

    private enum ProtocolError: Error { case invalid(String) }

    private final class Client {
        private enum State { case open(Int32), replying(Int32), closed }
        private let lock = NSLock()
        private let ioQueue: DispatchQueue
        private let onClose: () -> Void
        private var state: State

        init(fd: Int32, ioQueue: DispatchQueue, onClose: @escaping () -> Void) {
            state = .open(fd)
            self.ioQueue = ioQueue
            self.onClose = onClose
        }

        func close() {
            lock.lock()
            guard case let .open(fd) = state else { lock.unlock(); return }
            state = .closed
            lock.unlock()
            Darwin.close(fd)
            onClose()
        }

        func reply(_ object: [String: Any]) {
            lock.lock()
            guard case let .open(fd) = state else { lock.unlock(); return }
            state = .replying(fd)
            lock.unlock()
            ioQueue.async { self.send(object, fd: fd) }
        }

        private func send(_ object: [String: Any], fd: Int32) {
            let data: Data
            if JSONSerialization.isValidJSONObject(object), let encoded = try? JSONSerialization.data(withJSONObject: object), encoded.count < 1024 * 1024 {
                data = encoded
            } else {
                let errorReply: [String: Any] = ["id": object["id"] as? String ?? NSNull(), "ok": false, "error": "response_too_large"]
                guard let encoded = try? JSONSerialization.data(withJSONObject: errorReply) else { finishReply(fd); return }
                data = encoded
            }
            var output = data
            output.append(10)
            output.withUnsafeBytes { bytes in
                var offset = 0
                let deadline = Date().addingTimeInterval(5)
                while offset < output.count {
                    let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), output.count - offset, 0)
                    if sent > 0 { offset += sent; continue }
                    if sent < 0, errno == EINTR { continue }
                    if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        let remaining = deadline.timeIntervalSinceNow
                        guard remaining > 0 else { break }
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        guard Darwin.poll(&descriptor, 1, Int32(ceil(remaining * 1_000))) > 0 else { break }
                        continue
                    }
                    break
                }
            }
            finishReply(fd)
        }

        private func finishReply(_ fd: Int32) {
            lock.lock()
            guard case let .replying(current) = state, current == fd else { lock.unlock(); return }
            state = .closed
            lock.unlock()
            Darwin.close(fd)
            onClose()
        }
    }
}
