import Foundation
import Darwin

struct RigError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One TCP connection to Hamlib's rigctld, speaking its plain text protocol. Calls are
/// serialised on a private queue and every read has a deadline, so a dead radio can't hang the app.
final class RigLink: @unchecked Sendable {
    private let queue: DispatchQueue
    private var fd: Int32 = -1

    init(label: String) { queue = DispatchQueue(label: "vessel.rig.\(label)") }
    deinit { if fd >= 0 { close(fd) } }

    /// By default the loopback address: a radio attached to this Mac. A rotator's rotctld can be elsewhere.
    func connect(host: String = "127.0.0.1", port: Int) async throws {
        try await run { [self] in
            if fd >= 0 { close(fd); fd = -1 }
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { throw RigError(message: "No socket") }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
            addr.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)
            guard addr.sin_addr.s_addr != INADDR_NONE else { close(s); throw RigError(message: "\(host) isn't an IP address") }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard r == 0 else { close(s); throw RigError(message: "Nothing is answering on \(host) port \(port)") }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            fd = s
        }
    }

    func disconnect() {
        queue.async { [self] in if fd >= 0 { close(fd); fd = -1 } }
    }

    /// A set command: succeeds only on `RPRT 0`.
    func set(_ command: String) async throws {
        let reply = try await exchange(command, lines: 1)
        guard reply.first == "RPRT 0" else { throw RigError(message: "\(command): \(reply.first ?? "no reply")") }
    }

    /// A get command: the first reply line, failing if the radio answered with an error.
    func get(_ command: String, lines: Int = 1) async throws -> String {
        let reply = try await exchange(command, lines: lines)
        guard let first = reply.first, !first.hasPrefix("RPRT") else {
            throw RigError(message: "\(command): \(reply.first ?? "no reply")")
        }
        return first
    }

    /// A get command with several reply lines, like a rotator's azimuth and elevation.
    func lines(_ command: String, count: Int) async throws -> [String] {
        let reply = try await exchange(command, lines: count)
        if let first = reply.first, first.hasPrefix("RPRT") { throw RigError(message: "\(command): \(first)") }
        return reply
    }

    /// Blocking, for use during app shutdown.
    func setBlocking(_ command: String) {
        queue.sync { _ = try? self.send(command, lines: 1) }
    }

    private func exchange(_ command: String, lines: Int) async throws -> [String] {
        try await run { [self] in try send(command, lines: lines) }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try work() }) }
        }
    }

    private func send(_ command: String, lines: Int) throws -> [String] {
        guard fd >= 0 else { throw RigError(message: "Radio not connected") }
        let bytes = Array((command + "\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { drop(); throw RigError(message: "Radio link lost") }
        var out: [String] = []
        var line: [UInt8] = []
        var b: UInt8 = 0
        while out.count < lines {
            let n = read(fd, &b, 1)
            guard n == 1 else { drop(); throw RigError(message: "Radio link lost") }
            if b == 10 {
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                line = []
                out.append(text)
                if text.hasPrefix("RPRT") { break }
            } else {
                line.append(b)
            }
        }
        return out
    }

    private func drop() { if fd >= 0 { close(fd); fd = -1 } }
}
