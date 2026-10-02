import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct IPCError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public let errnoCode: Int32?
    public init(_ description: String, errnoCode: Int32? = nil) {
        self.description = description
        self.errnoCode = errnoCode
    }
}

public struct IPCArguments: Codable, Sendable {
    public var minutes: Int?
    public var did: Bool?
    public var other: String?
    public var startNext: Bool?
    public var on: Bool?
    public init(minutes: Int? = nil, did: Bool? = nil, other: String? = nil, startNext: Bool? = nil, on: Bool? = nil) {
        self.minutes = minutes; self.did = did; self.other = other; self.startNext = startNext; self.on = on
    }
}

public struct IPCRequest: Codable, Sendable {
    public var v: Int
    public var cmd: String
    public var args: IPCArguments?
    public init(v: Int = 1, cmd: String, args: IPCArguments? = nil) {
        self.v = v; self.cmd = cmd; self.args = args
    }

    public func command() throws -> Command {
        guard v == 1 else { throw IPCError("Unsupported protocol version.") }
        if let minutes = args?.minutes, minutes <= 0 || minutes > Int.max / 60 {
            throw IPCError("Minutes must be positive and fit in seconds.")
        }
        switch cmd {
        case "start": return .start
        case "start_break": return .startBreak
        case "pause": return .pause
        case "resume": return .resume
        case "toggle": return .toggle
        case "next": return .next
        case "restart": return .restart
        case "extend": return .extend(args?.minutes)
        case "reset": return .reset
        case "end_break": return .endBreak
        case "lunch": return .lunch(args?.minutes)
        case "end_lunch": return .endLunch
        case "not_today":
            guard let on = args?.on else { throw IPCError("not_today requires on.") }
            return .notToday(on)
        case "answer":
            guard (args?.did == true) != (args?.other != nil) else { throw IPCError("Choose either did or other.") }
            return .answer(args?.did == true ? .didSuggested : .other(args!.other!), startNext: args?.startNext ?? true)
        case "settings": return .settings
        default: throw IPCError("Unknown command: \(cmd).")
        }
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var state: State?
    public var code: String?
    public var error: String?
    public var debug: EngineDebug?
    public init(ok: Bool, state: State? = nil, code: String? = nil, error: String? = nil, debug: EngineDebug? = nil) {
        self.ok = ok; self.state = state; self.code = code; self.error = error
        self.debug = debug
    }
}

public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}

private enum UnixSocket {
    struct Deadline {
        private let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var milliseconds: Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            return now >= end ? 0 : Int32((end - now + 999_999) / 1_000_000)
        }
    }

    static func create() throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw failure("Create socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        #if !os(Linux)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
        #endif
        return fd
    }

    static func address(_ path: String) throws -> sockaddr_un {
        guard path.utf8.count < 104 else { throw IPCError("Socket path exceeds 103 UTF-8 bytes.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if !os(Linux)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        return address
    }

    static func connectTo(_ path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try create()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0 {
            if errno == EINPROGRESS {
                do {
                    guard try ready(fd, events: Int16(POLLOUT)) else { throw IPCError("Socket connect timed out after 2 seconds.") }
                    var code: Int32 = 0
                    var length = socklen_t(MemoryLayout.size(ofValue: code))
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 else {
                        throw IPCError("Engine not running or socket unreachable.", errnoCode: code)
                    }
                } catch { _ = close(fd); throw error }
            } else {
                let error = failure("Engine not running or socket unreachable"); _ = close(fd); throw error
            }
        }
        return fd
    }

    static func failure(_ operation: String) -> IPCError {
        let code = errno
        return IPCError("\(operation): \(String(cString: strerror(code))).", errnoCode: code)
    }

    static func ready(_ fd: Int32, events: Int16, timeout: Int32 = 2_000) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, timeout)
        if result < 0 {
            if errno == EINTR { return false }
            throw failure("Poll socket")
        }
        return result > 0
    }

    static func readLine(_ fd: Int32, deadline: Deadline = Deadline()) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= 1_048_576 {
            guard deadline.milliseconds > 0,
                  try ready(fd, events: Int16(POLLIN), timeout: deadline.milliseconds) else { throw IPCError("Socket timed out after 2 seconds.") }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                if data.isEmpty { return data }
                throw IPCError("Socket closed before newline.")
            }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw failure("Read socket")
            }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<newline])
                guard data.count <= 1_048_576 else { throw IPCError("Socket message exceeds 1 MiB.") }
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw IPCError("Socket message exceeds 1 MiB.")
    }

    static func write(_ data: Data, to fd: Int32, deadline: Deadline = Deadline()) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard deadline.milliseconds > 0,
                      try ready(fd, events: Int16(POLLOUT), timeout: deadline.milliseconds) else { throw IPCError("Socket timed out after 2 seconds.") }
                #if os(Linux)
                let count = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let count = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                #endif
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw failure("Write socket") }
                offset += count
            }
        }
    }
}

public enum IPCClient {
    public static func request(_ request: IPCRequest, path: String) throws -> IPCResponse {
        let deadline = UnixSocket.Deadline()
        let fd = try UnixSocket.connectTo(path)
        defer { _ = close(fd) }
        try UnixSocket.write(IPCCodec.encode(request), to: fd, deadline: deadline)
        return try IPCCodec.decode(IPCResponse.self, from: UnixSocket.readLine(fd, deadline: deadline))
    }
}

// The owner closes the server only after its serial serving loop has stopped.
public final class IPCServer: @unchecked Sendable {
    private var fd: Int32
    private let path: String

    public init(path: String) throws {
        _ = try UnixSocket.address(path)
        do {
            let existing = try UnixSocket.connectTo(path)
            _ = DarwinOrGlibcClose(existing)
            throw IPCError("An engine is already running.")
        } catch let error as IPCError {
            guard error.errnoCode == ENOENT || error.errnoCode == ECONNREFUSED else { throw error }
            if error.errnoCode == ECONNREFUSED {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard attributes[.type] as? FileAttributeType == .typeSocket else {
                    throw IPCError("Socket path exists and is not a socket.")
                }
                _ = unlink(path)
            }
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = try UnixSocket.create()
        self.path = path
        var address = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if bound < 0 { let error = UnixSocket.failure("Bind socket"); _ = DarwinOrGlibcClose(fd); throw error }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let error = UnixSocket.failure("Listen on socket")
            _ = DarwinOrGlibcClose(fd); _ = unlink(path); throw error
        }
    }

    @discardableResult
    public func serveOne(timeoutMilliseconds: Int32 = 1_000, handler: (IPCRequest) -> IPCResponse) throws -> Bool {
        guard try UnixSocket.ready(fd, events: Int16(POLLIN), timeout: timeoutMilliseconds) else { return false }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { throw UnixSocket.failure("Accept socket") }
        defer { _ = DarwinOrGlibcClose(client) }
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        #if !os(Linux)
        var on: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
        #endif
        let data = try UnixSocket.readLine(client)
        if data.isEmpty { return false } // A startup single-instance probe just connects and closes.
        let response: IPCResponse
        do { response = handler(try IPCCodec.decode(IPCRequest.self, from: data)) }
        catch { response = IPCResponse(ok: false, code: "usage", error: "Malformed request: \(error)") }
        try UnixSocket.write(IPCCodec.encode(response), to: client)
        return true
    }

    public func close(removeSocket: Bool = true) {
        if fd >= 0 {
            _ = DarwinOrGlibcClose(fd); fd = -1
            if removeSocket { _ = unlink(path) }
        }
    }
    deinit { if fd >= 0 { _ = DarwinOrGlibcClose(fd); _ = unlink(path) } }
}

private func DarwinOrGlibcClose(_ fd: Int32) -> Int32 {
    #if os(Linux)
    Glibc.close(fd)
    #else
    Darwin.close(fd)
    #endif
}

public func processIsRunning(_ pid: Int) -> Bool {
    guard pid > 0, pid <= Int(Int32.max) else { return false }
    return kill(Int32(pid), 0) == 0 || errno == EPERM
}
