import Foundation
import Network

// Short-lived sensor transport. URLSessionWebSocketTask retained completed tasks
// through CFNetwork on macOS 27, even after session invalidation. Own the native
// connection directly and clear its callbacks when each poll finishes.
nonisolated final class NanitClimateSocket: @unchecked Sendable {
    let connection: NWConnection
    let messages: AsyncThrowingStream<Data?, Error>
    private let continuation: AsyncThrowingStream<Data?, Error>.Continuation
    private let queue = DispatchQueue(label: "com.tanooj.Nanight.climate")
    private var finished = false // Accessed only on queue.

    init(request: URLRequest) throws {
        guard let url = request.url, ["ws", "wss"].contains(url.scheme) else { throw URLError(.badURL) }
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 1_048_576
        options.setAdditionalHeaders((request.allHTTPHeaderFields ?? [:]).map { (name: $0.key, value: $0.value) })
        let parameters = url.scheme == "wss" ? NWParameters.tls : NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        let stream = AsyncThrowingStream<Data?, Error>.makeStream(bufferingPolicy: .bufferingOldest(6))
        messages = stream.stream
        continuation = stream.continuation
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error), .waiting(let error): self?.finish(throwing: error)
                case .cancelled: self?.finish(throwing: CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
            receive()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !finished else { result.resume(throwing: CancellationError()); return }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "sensor-request", metadata: [metadata])
                connection.send(content: data, contentContext: context, completion: .contentProcessed { error in
                    if let error { result.resume(throwing: error) }
                    else { result.resume() }
                })
            }
        }
    }

    func close() {
        queue.async { [self] in finish(throwing: CancellationError()) }
    }

    private func finish(throwing error: Error) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.finish(throwing: error)
    }

    private func receive() {
        guard !finished else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(throwing: error); return }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                self.finish(throwing: URLError(.badServerResponse)); return
            }
            switch metadata.opcode {
            case .binary, .text:
                if case .dropped = self.continuation.yield(metadata.opcode == .binary ? (data ?? Data()) : nil) {
                    self.finish(throwing: URLError(.dataLengthExceedsMaximum)); return
                }
            case .close:
                self.finish(throwing: URLError(.networkConnectionLost)); return
            default: break
            }
            self.receive()
        }
    }
}
