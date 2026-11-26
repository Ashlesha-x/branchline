import Foundation
import Darwin

public final class WorkspaceProcessLock: @unchecked Sendable {
    private let descriptor: Int32
    public init(directory: URL) throws {
        descriptor = Darwin.open(directory.appendingPathComponent("workspace.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceError("无法建立资料库进程锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw WorkspaceError("此资料库已由另一个脉络进程打开，请使用现有窗口。") }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

public struct BridgeEndpoint: Codable, Sendable {
    public var port: UInt16
    public var token: String
    public var pid: Int32
    public var apiVersion: String
}

/// Bounds the number of connections served at once; each one holds a thread while it waits.
private final class ConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    let limit = 8
    func enter() -> Bool { lock.lock(); defer { lock.unlock() }; guard active < limit else { return false }; active += 1; return true }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func set(_ value: Data) { lock.lock(); bytes = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// The app waits up to `bridgeHandlerTimeout` for the main thread; clients wait longer than
/// that so they always receive the app's answer, including its timeout answer.
let bridgeHandlerTimeout = 30
private func configure(_ fd: Int32, receiveSeconds: Int = 10) {
    var receive = timeval(tv_sec: receiveSeconds, tv_usec: 0), send = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
}
private func readMessage(_ fd: Int32, limit: Int) throws -> Data {
    var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while result.count <= limit {
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            throw WorkspaceError("bridge_timeout: 等待脉络响应超时。写入可能已经生效：请用 get_operation_result 查询同一 requestID，不要换新 requestID 重试。")
        }
        guard count > 0 else { throw WorkspaceError("bridge_unavailable: 本地连接中断，请确认脉络已运行。") }
        if let newline = buffer.prefix(count).firstIndex(of: 10) { result.append(contentsOf: buffer[..<newline]); guard result.count <= limit else { break }; return result }
        result.append(contentsOf: buffer.prefix(count))
    }
    throw WorkspaceError("message_too_large")
}
private func writeMessage(_ fd: Int32, data: Data) throws {
    let message = data + Data([10])
    try message.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let sent = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
            guard sent > 0 else { throw WorkspaceError("bridge_send_failed") }; offset += sent
        }
    }
}

// The endpoint is a loopback-only, token-authenticated JSON socket, not an HTTP server.
// MCP processes are adapters and never open the database.
public final class LocalBridgeServer: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    public let endpoint: BridgeEndpoint
    private let endpointURL: URL
    public init(directory: URL, handler: @escaping @MainActor @Sendable (JSONValue) -> JSONValue) throws {
        let listenerFD = socket(AF_INET, SOCK_STREAM, 0)
        fd = listenerFD
        guard fd >= 0 else { throw WorkspaceError("bridge_socket_failed") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { Darwin.close(fd); throw WorkspaceError("bridge_listen_failed") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenerFD, $0, &size) } }
        endpoint = BridgeEndpoint(port: UInt16(bigEndian: address.sin_port), token: UUID().uuidString + UUID().uuidString, pid: getpid(), apiVersion: AutomationAPI.version)
        let bytes = try JSONValue.encoder.encode(endpoint)
        endpointURL = directory.appendingPathComponent("automation-endpoint.json")
        // Create the token file as 0600 from the outset, including before rename.
        let temporary = directory.appendingPathComponent(".automation-endpoint-" + UUID().uuidString)
        let tokenFD = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard tokenFD >= 0 else { Darwin.close(fd); throw WorkspaceError("endpoint_write_failed") }
        let written = bytes.withUnsafeBytes { Darwin.write(tokenFD, $0.baseAddress!, $0.count) }
        _ = fsync(tokenFD); Darwin.close(tokenFD)
        guard written == bytes.count, rename(temporary.path, directory.appendingPathComponent("automation-endpoint.json").path) == 0 else { Darwin.close(fd); throw WorkspaceError("endpoint_write_failed") }
        let token = endpoint.token, listener = fd, gate = ConnectionGate()
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "branchline.bridge.accept"))
        source.setEventHandler {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            guard gate.enter() else {
                configure(client)
                if let data = try? JSONValue.encoder.encode(JSONValue.object(["ok": .bool(false), "error": .string("busy: 同时进行的请求过多，请稍后重试。")])) { try? writeMessage(client, data: data) }
                Darwin.close(client); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { Darwin.close(client); gate.leave() }; configure(client)
                do {
                    let request = try JSONValue.decoder.decode(JSONValue.self, from: readMessage(client, limit: 1_048_576))
                    guard request["token"].string == token else { try writeMessage(client, data: JSONValue.encoder.encode(JSONValue.object(["ok": .bool(false), "error": .string("unauthorized")]))); return }
                    let box = ReplyBox(), semaphore = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        let result = handler(request)
                        box.set((try? JSONValue.encoder.encode(result)) ?? Data("{}".utf8)); semaphore.signal()
                    }
                    // An ambiguous timeout must be resolved using get_operation_result, not a new request ID.
                    guard semaphore.wait(timeout: .now() + .seconds(bridgeHandlerTimeout)) == .success else {
                        let message = "timeout: 脉络暂时忙碌，操作可能仍会完成。请用 get_operation_result 查询同一 requestID，不要换新 requestID 重试。"
                        try writeMessage(client, data: JSONValue.encoder.encode(JSONValue.object(["ok": .bool(false), "error": .string(message)])))
                        return
                    }
                    try writeMessage(client, data: box.get())
                } catch { let response = JSONValue.object(["ok": .bool(false), "error": .string(error.localizedDescription)]); if let data = try? JSONValue.encoder.encode(response) { try? writeMessage(client, data: data) } }
            }
        }
        source.setCancelHandler { Darwin.close(listener) }
        source.resume()
    }
    /// Removes the endpoint file if it still belongs to this server, so clients stop
    /// connecting to a port that is no longer ours after the app quits.
    public func invalidate() {
        source.cancel()
        guard let data = try? Data(contentsOf: endpointURL),
              let current = try? JSONValue.decoder.decode(BridgeEndpoint.self, from: data), current.token == endpoint.token else { return }
        try? FileManager.default.removeItem(at: endpointURL)
    }
    deinit { source.cancel() }
}

public enum LocalBridgeClient {
    public static var defaultDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Branchline") }
    public static func call(directory: URL, method: String, arguments: JSONValue) throws -> JSONValue {
        let url = directory.appendingPathComponent("automation-endpoint.json")
        guard let data = try? Data(contentsOf: url), let endpoint = try? JSONValue.decoder.decode(BridgeEndpoint.self, from: data) else { throw WorkspaceError("bridge_unavailable: 请先启动支持本地接口的脉络，并开启外部访问。") }
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw WorkspaceError("socket_failed") }; defer { Darwin.close(fd) }; configure(fd, receiveSeconds: bridgeHandlerTimeout + 10)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = endpoint.port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw WorkspaceError("bridge_unavailable: 请启动脉络；关闭窗口可继续调用，完全退出后不可调用。") }
        let request = JSONValue.object(["token": .string(endpoint.token), "method": .string(method), "arguments": arguments])
        try writeMessage(fd, data: JSONValue.encoder.encode(request))
        return try JSONValue.decoder.decode(JSONValue.self, from: readMessage(fd, limit: 16_777_216))
    }
}
