import CryptoKit
import Foundation
import Network
import Testing
@testable import Nanight

@MainActor
struct ClimateConnectionTests {
    @Test func repeatedPollsReleaseRealWebSocketsEvenWhenPeerIgnoresClose() async throws {
        let server = try ClimateTestServer(mode: .success)
        let url = try await server.start()
        defer { server.stop() }
        let tracker = ClimateSocketTracker()
        let restSession = URLSession(configuration: .ephemeral)
        defer { restSession.invalidateAndCancel() }
        let client = NanitAPIClient(session: restSession, baseURL: url, climateSocketFactory: { try tracker.makeSocket(request: $0) })
        for _ in 0..<100 {
            let reading = try await client.climate(accessToken: "test", cameraUID: "test")
            #expect(reading?.temperatureCelsius == 22.3)
            #expect(reading?.humidityPercent == 45.5)
        }
        try await waitUntil { tracker.retainedSockets == 0 && server.connections == 0 }
        #expect(tracker.opened == 100)
        #expect(tracker.retainedSockets == 0)
        #expect(server.connections == 0)
        // Climate cleanup must not invalidate the separate REST session.
        let (_, response) = try await restSession.data(from: url.appendingPathComponent("health"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test(arguments: [ClimateTestServer.Mode.noReading, .malformed, .disconnect])
    fileprivate func responsePathsReleaseTheirConnection(mode: ClimateTestServer.Mode) async throws {
        let server = try ClimateTestServer(mode: mode)
        let url = try await server.start()
        defer { server.stop() }
        let tracker = ClimateSocketTracker()
        let client = NanitAPIClient(baseURL: url, climateSocketFactory: { try tracker.makeSocket(request: $0) })
        do {
            let reading = try await client.climate(accessToken: "test", cameraUID: "test")
            #expect(mode == .noReading && reading == nil)
        } catch { #expect(mode != .noReading) }
        try await waitUntil { tracker.retainedSockets == 0 && server.connections == 0 }
    }

    @Test(arguments: [ClimateTestServer.Mode.stallHandshake, .stallResponse])
    fileprivate func deadlineClosesStalledIO(mode: ClimateTestServer.Mode) async throws {
        let server = try ClimateTestServer(mode: mode)
        let url = try await server.start()
        defer { server.stop() }
        let tracker = ClimateSocketTracker()
        let client = NanitAPIClient(baseURL: url, climateSocketFactory: { try tracker.makeSocket(request: $0) }, climateTimeout: .milliseconds(200))
        let started = ContinuousClock.now
        do {
            _ = try await client.climate(accessToken: "test", cameraUID: "test")
            Issue.record("A stalled request should fail")
        } catch {}
        #expect(started.duration(to: .now) < .seconds(2))
        try await waitUntil { tracker.retainedSockets == 0 && server.connections == 0 }
    }

    @Test(arguments: [ClimateTestServer.Mode.stallHandshake, .stallResponse])
    fileprivate func cancellationClosesStalledIO(mode: ClimateTestServer.Mode) async throws {
        let server = try ClimateTestServer(mode: mode)
        let url = try await server.start()
        defer { server.stop() }
        let tracker = ClimateSocketTracker()
        let client = NanitAPIClient(baseURL: url, climateSocketFactory: { try tracker.makeSocket(request: $0) })
        let task = Task { try await client.climate(accessToken: "test", cameraUID: "test") }
        defer { task.cancel() }
        try await waitUntil { server.connections == 1 && (mode == .stallHandshake || server.requests == 1) }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled request should fail")
        } catch {}
        #expect(cancelledAt.duration(to: .now) < .seconds(2))
        try await waitUntil { tracker.retainedSockets == 0 && server.connections == 0 }
    }

    @Test func alreadyCancelledPollDoesNotCreateASocket() async {
        var created = false
        let client = NanitAPIClient(climateSocketFactory: { request in
            created = true
            return try NanitClimateSocket(request: request)
        })
        let task = Task { try await client.climate(accessToken: "test", cameraUID: "test") }
        task.cancel()
        _ = await task.result
        #expect(!created)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

private final class ClimateSocketTracker {
    private final class WeakSocket {
        weak var value: NanitClimateSocket?
        weak var connection: NWConnection?
        init(_ value: NanitClimateSocket) { self.value = value; connection = value.connection }
    }
    private var sockets: [WeakSocket] = []
    var opened: Int { sockets.count }
    var retainedSockets: Int { sockets.filter { $0.value != nil || $0.connection != nil }.count }

    func makeSocket(request: URLRequest) throws -> NanitClimateSocket {
        let socket = try NanitClimateSocket(request: request)
        sockets.append(WeakSocket(socket))
        return socket
    }
}

// A localhost-only camera substitute. It intentionally ignores WebSocket close
// frames, so graceful close alone cannot pass the connection-release regression.
private final class ClimateTestServer: @unchecked Sendable {
    enum Mode: Sendable { case success, noReading, malformed, disconnect, stallHandshake, stallResponse }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "NanightTests.climate-server")
    private let mode: Mode
    private var clients: [UUID: Client] = [:]
    private var requestCount = 0
    var connections: Int { queue.sync { clients.count } }
    var requests: Int { queue.sync { requestCount } }

    init(mode: Mode) throws {
        self.mode = mode
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            let client = Client(connection: connection, mode: self.mode,
                                onRequest: { [weak self] in self?.requestCount += 1 },
                                onClose: { [weak self] in self?.clients[id] = nil })
            self.clients[id] = client
            client.start(on: self.queue)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
        }
    }

    private final class Client {
        let connection: NWConnection
        let mode: Mode
        let onRequest: () -> Void
        let onClose: () -> Void
        var buffer: [UInt8] = []
        var upgraded = false

        init(connection: NWConnection, mode: Mode, onRequest: @escaping () -> Void, onClose: @escaping () -> Void) {
            self.connection = connection; self.mode = mode; self.onRequest = onRequest; self.onClose = onClose
        }

        func start(on queue: DispatchQueue) {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed: self?.onClose()
                default: break
                }
            }
            connection.start(queue: queue)
            receive()
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { self.buffer += data; self.process() }
                if complete || error != nil { self.connection.cancel() }
                else { self.receive() }
            }
        }

        func process() {
            if !upgraded {
                let headers = String(decoding: buffer, as: UTF8.self)
                guard let end = headers.range(of: "\r\n\r\n") else { return }
                if headers.hasPrefix("GET /health ") {
                    send(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    return
                }
                guard mode != .stallHandshake else { return }
                guard headers.hasPrefix("GET /focus/cameras/test/user_connect "),
                      headers.lowercased().contains("authorization: bearer test\r\n") else {
                    connection.cancel(); return
                }
                let key = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }!
                    .split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
                send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n".utf8))
                buffer.removeFirst(headers[..<end.upperBound].utf8.count)
                upgraded = true
            }
            // Sensor requests in this fixture fit in a single masked short frame.
            while buffer.count >= 6 {
                let size = Int(buffer[1] & 127)
                guard size < 126, buffer.count >= size + 6 else { return }
                let opcode = buffer[0] & 15
                let mask = Array(buffer[2..<6])
                let payload = (0..<size).map { buffer[6 + $0] ^ mask[$0 % 4] }
                buffer.removeFirst(size + 6)
                guard opcode == 2 else { continue }
                onRequest()
                switch mode {
                case .disconnect: connection.cancel()
                case .stallResponse, .stallHandshake: break
                case .noReading: for _ in 0..<6 { send(Data([0x81, 1, 120])) }
                case .malformed: send(Data([0x82, 1, 0xff]))
                case .success:
                    var index = 0
                    func readVarint() -> UInt64 {
                        var value: UInt64 = 0, shift: UInt64 = 0
                        while index < payload.count {
                            let byte = payload[index]; index += 1
                            value |= UInt64(byte & 127) << shift
                            if byte < 128 { break }
                            shift += 7
                        }
                        return value
                    }
                    for _ in 0..<5 { _ = readVarint() }
                    let id = readVarint()
                    let temperature = [UInt8(8), 2, 48] + varint(22_300)
                    let humidity = [UInt8(8), 3, 48] + varint(45_500)
                    let response = [UInt8(8)] + varint(id) + [16, 12, 24, 0, 74, UInt8(temperature.count)]
                        + temperature + [74, UInt8(humidity.count)] + humidity
                    let message = [UInt8(8), 2, 26, UInt8(response.count)] + response
                    send(Data([0x82, UInt8(message.count)] + message))
                }
            }
        }

        func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
            bytes.append(UInt8(value))
            return bytes
        }
    }
}
