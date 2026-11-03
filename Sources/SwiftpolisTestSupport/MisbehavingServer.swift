import CryptoKit
import Foundation
import Network

/// A local HTTP/1.1 server that serves predictable bytes and fails on request.
public final class MisbehavingServer: @unchecked Sendable {
    public struct Behaviour: Sendable {
        public var size: Int64
        public var advertisesRanges = true
        public var honoursRanges = true
        public var sendsLength = true
        public var etag: String?
        public var contentDisposition: String?
        public var headStatus: Int?
        public var getStatus: Int?
        /// Answers this many GET requests with `failingStatus` before behaving.
        public var failFirstGets = 0
        public var failingStatus = 503
        /// Closes this many GET requests halfway through their body before behaving.
        public var dropFirstGets = 0
        public var secondsPerMiB: Double = 0
        public var redirectTo: String?
        /// When set, requests must carry this `Proxy-Authorization` value or get a 407.
        public var requiredProxyAuthorization: String?

        public init(size: Int64) {
            self.size = size
        }
    }

    public struct Request: Sendable {
        public let method: String
        public let target: String
        public let headers: [String: String]

        public var range: String? { headers["range"] }
    }

    private let lock = NSLock()
    private var behaviourStorage: Behaviour
    private var requestLog: [Request] = []
    private var getCount = 0
    private var activeGets = 0
    private var maximumActiveGets = 0
    private var bytesServedTotal: Int64 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "MisbehavingServer", attributes: .concurrent)

    public init(_ behaviour: Behaviour) {
        behaviourStorage = behaviour
    }

    public var behaviour: Behaviour {
        get { lock.withLock { behaviourStorage } }
        set { lock.withLock { behaviourStorage = newValue } }
    }

    public var requests: [Request] { lock.withLock { requestLog } }
    public var gets: [Request] { requests.filter { $0.method == "GET" } }
    public var maximumSimultaneousGets: Int { lock.withLock { maximumActiveGets } }
    public var bytesServed: Int64 { lock.withLock { bytesServedTotal } }

    public func resetLog() {
        lock.withLock {
            requestLog = []
            getCount = 0
            maximumActiveGets = 0
            bytesServedTotal = 0
        }
    }

    public var port: UInt16 { listener?.port?.rawValue ?? 0 }

    public func url(_ name: String = "file.bin", host: String = "127.0.0.1") -> String {
        "http://\(host):\(port)/\(name)"
    }

    public func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            Task { await handle(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
    }

    // MARK: Handling a connection

    private func handle(_ connection: NWConnection) async {
        defer { connection.cancel() }
        guard let request = await readRequest(from: connection) else { return }
        lock.withLock { requestLog.append(request) }

        let behaviour = self.behaviour
        if let required = behaviour.requiredProxyAuthorization,
           request.headers["proxy-authorization"] != required {
            await respond(407, ["Proxy-Authenticate": "Basic realm=\"test\"", "Content-Length": "0"], to: connection)
            return
        }

        switch request.method {
        case "HEAD":
            await respond(behaviour.headStatus ?? behaviour.getStatus ?? 200, commonHeaders(behaviour), to: connection)
        case "GET":
            let attempt = lock.withLock {
                getCount += 1
                activeGets += 1
                maximumActiveGets = max(maximumActiveGets, activeGets)
                return getCount
            }
            let finished = Once()
            let markFinished = { finished.run { self.lock.withLock { self.activeGets -= 1 } } }
            await serveGet(request, behaviour: behaviour, attempt: attempt, to: connection, beforeLastPiece: markFinished)
            markFinished()
        default:
            await respond(405, ["Content-Length": "0"], to: connection)
        }
    }

    private func commonHeaders(_ behaviour: Behaviour) -> [String: String] {
        var headers: [String: String] = [:]
        if behaviour.sendsLength { headers["Content-Length"] = String(behaviour.size) }
        if behaviour.advertisesRanges { headers["Accept-Ranges"] = "bytes" }
        if let etag = behaviour.etag { headers["ETag"] = etag }
        if let disposition = behaviour.contentDisposition { headers["Content-Disposition"] = disposition }
        return headers
    }

    private func serveGet(
        _ request: Request,
        behaviour: Behaviour,
        attempt: Int,
        to connection: NWConnection,
        beforeLastPiece: () -> Void
    ) async {
        if let redirect = behaviour.redirectTo {
            await respond(302, ["Location": redirect, "Content-Length": "0"], to: connection)
            return
        }
        let failing = attempt <= behaviour.failFirstGets ? behaviour.failingStatus : behaviour.getStatus
        if let failing, failing != 200 {
            let body = Data(repeating: UInt8(ascii: "e"), count: 110)
            await respond(failing, ["Content-Length": String(body.count)], body: body, to: connection)
            return
        }

        let size = behaviour.size
        var start: Int64 = 0
        var end = size - 1
        var isPartial = false
        if behaviour.honoursRanges, let range = request.range, range.hasPrefix("bytes=") {
            let pieces = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            start = pieces.first.flatMap { Int64($0) } ?? 0
            end = pieces.count > 1 ? Int64(pieces[1]) ?? end : end
            isPartial = true
        }
        if isPartial, start >= size {
            await respond(416, ["Content-Length": "0"], to: connection)
            return
        }

        let length = max(0, end - start + 1)
        var headers: [String: String] = [:]
        if behaviour.advertisesRanges { headers["Accept-Ranges"] = "bytes" }
        if let etag = behaviour.etag { headers["ETag"] = etag }
        if let disposition = behaviour.contentDisposition { headers["Content-Disposition"] = disposition }
        if behaviour.sendsLength || isPartial { headers["Content-Length"] = String(length) }
        if isPartial { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        await respond(isPartial ? 206 : 200, headers, to: connection)

        let dropAt = attempt <= behaviour.dropFirstGets ? length / 2 : nil
        var sent: Int64 = 0
        let pieceSize: Int64 = 128 * 1024
        while sent < length {
            if let dropAt, sent >= dropAt {
                connection.forceCancel()
                return
            }
            let take = min(pieceSize, length - sent)
            // Once the client has the last byte it may start its next request, so this one must
            // already have stopped counting as active.
            if sent + take == length { beforeLastPiece() }
            guard await send(TestContent.bytes(start: start + sent, length: Int(take)), on: connection) else { return }
            sent += take
            lock.withLock { bytesServedTotal += take }
            if behaviour.secondsPerMiB > 0, sent < length {
                let seconds = behaviour.secondsPerMiB * Double(take) / 1_048_576
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func respond(
        _ status: Int,
        _ headers: [String: String],
        body: Data = Data(),
        to connection: NWConnection
    ) async {
        var head = "HTTP/1.1 \(status) Status\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        _ = await send(Data(head.utf8) + body, on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func readRequest(from connection: NWConnection) async -> Request? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            let piece: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let piece, !piece.isEmpty else { return nil }
            buffer.append(piece)
        }
        let lines = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[line[..<colon].lowercased()] = value
        }
        return Request(method: String(first[0]), target: String(first[1]), headers: headers)
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false

    func run(_ body: () -> Void) {
        let shouldRun = lock.withLock {
            defer { hasRun = true }
            return !hasRun
        }
        if shouldRun { body() }
    }
}

/// Bytes where the one at offset N is always N % 251, so any misplaced byte changes the hash.
public enum TestContent {
    public static func bytes(start: Int64, length: Int) -> Data {
        var data = Data(count: length)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var value = UInt8(start % 251)
            for index in 0..<length {
                buffer[index] = value
                value = value == 250 ? 0 : value + 1
            }
        }
        return data
    }

    /// Whether a file is exactly the content a server of this size would serve.
    public static func isIntact(path: String, size: Int64) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var actual = SHA256()
        var expected = SHA256()
        var offset: Int64 = 0
        var total: Int64 = 0
        while let piece = try? handle.read(upToCount: 1_048_576), !piece.isEmpty {
            actual.update(data: piece)
            total += Int64(piece.count)
        }
        guard total == size else { return false }
        while offset < size {
            let take = min(1_048_576, size - offset)
            expected.update(data: bytes(start: offset, length: Int(take)))
            offset += take
        }
        return actual.finalize() == expected.finalize()
    }
}
