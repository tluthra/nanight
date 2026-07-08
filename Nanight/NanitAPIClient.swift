import Foundation

enum NanitAPIError: LocalizedError, Equatable {
    case invalidResponse
    case invalidCredentials
    case mfaRequired(String)
    case authExpired(String)
    case server(String)
    case transport(String)
    case noCamera

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Unexpected Nanit API response."
        case .invalidCredentials:
            return "Invalid Nanit email or password."
        case .mfaRequired:
            return "MFA code required."
        case .authExpired(let message):
            return message
        case .server(let message):
            return message
        case .transport(let message):
            return message
        case .noCamera:
            return "No Nanit cameras were found on this account."
        }
    }
}

struct NanitProtocolReference: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
    let note: String
}

final class NanitAPIClient {
    static let defaultBaseURL = URL(string: "https://api.nanit.com")!
    static let cloudMediaHost = "media-secured.nanit.com"

    static let protocolReferences: [NanitProtocolReference] = [
        NanitProtocolReference(
            title: "wealthystudent/ha-nanit",
            url: URL(string: "https://github.com/wealthystudent/ha-nanit")!,
            note: "Recent Home Assistant integration with REST auth, cloud event polling, RTMPS URLs, WebSocket protobuf controls, and local LAN fallback."
        ),
        NanitProtocolReference(
            title: "indiefan/home_assistant_nanit",
            url: URL(string: "https://github.com/indiefan/home_assistant_nanit")!,
            note: "Go bridge that mirrors Nanit camera feeds and documents the same login, refresh, babies, messages, and cloud WebSocket flow."
        ),
        NanitProtocolReference(
            title: "ranamobile/python-nanit",
            url: URL(string: "https://github.com/ranamobile/python-nanit")!,
            note: "Older Python client useful for additional Nanit REST endpoints such as connection status, events, users, and night settings."
        )
    ]

    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL = NanitAPIClient.defaultBaseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    func login(email: String, password: String) async throws -> NanitTokens {
        let body = ["email": email, "password": password]
        return try await authRequest(body: body)
    }

    func completeMFA(
        email: String,
        password: String,
        mfaToken: String,
        mfaCode: String
    ) async throws -> NanitTokens {
        let body = [
            "email": email,
            "password": password,
            "mfa_token": mfaToken,
            "mfa_code": mfaCode
        ]
        return try await authRequest(body: body)
    }

    func refresh(accessToken: String, refreshToken: String) async throws -> NanitTokens {
        var request = makeRequest(path: "/tokens/refresh", method: "POST", accessToken: accessToken)
        request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])

        let body = try await decodedBody(for: request)
        if let message = extractErrorMessage(from: body) {
            throw NanitAPIError.authExpired(message)
        }

        guard let accessToken = body["access_token"] as? String,
              let refreshToken = body["refresh_token"] as? String
        else {
            throw NanitAPIError.invalidResponse
        }

        return NanitTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    func babies(accessToken: String) async throws -> [NanitBaby] {
        let request = makeRequest(path: "/babies", method: "GET", accessToken: accessToken)
        do {
            return try await decodeBabies(for: request)
        } catch NanitAPIError.invalidCredentials {
            var bearerRequest = makeRequest(path: "/babies", method: "GET")
            bearerRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return try await decodeBabies(for: bearerRequest)
        }
    }

    func messages(accessToken: String, babyUID: String, limit: Int = 20) async throws -> [NanitCloudEvent] {
        var components = URLComponents(
            url: apiURL(path: "/babies/\(babyUID)/messages"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        guard let url = components?.url else {
            throw NanitAPIError.invalidResponse
        }

        var request = makeRequest(url: url, method: "GET", accessToken: accessToken)
        do {
            return try await decodeMessages(for: request, babyUID: babyUID)
        } catch NanitAPIError.invalidCredentials {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return try await decodeMessages(for: request, babyUID: babyUID)
        }
    }

    func connectionStatus(accessToken: String, cameraUID: String) async throws -> String? {
        let request = makeRequest(
            path: "/focus/cameras/\(cameraUID)/connection_status",
            method: "GET",
            accessToken: accessToken
        )
        let body = try await decodedBody(for: request)
        if let status = body["status"] as? String {
            return status
        }
        if let connected = body["connected"] as? Bool {
            return connected ? "connected" : "offline"
        }
        return nil
    }

    func snapshot(accessToken: String, babyUID: String) async throws -> Data? {
        let request = makeRequest(path: "/babies/\(babyUID)/snapshot", method: "GET", accessToken: accessToken)
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NanitAPIError.invalidResponse
            }
            return httpResponse.statusCode == 200 ? data : nil
        } catch let error as NanitAPIError {
            throw error
        } catch {
            throw NanitAPIError.transport(error.localizedDescription)
        }
    }

    func rtmpsStreamURL(babyUID: String, accessToken: String) -> URL? {
        URL(string: "rtmps://\(Self.cloudMediaHost)/nanit/\(babyUID).\(accessToken)")
    }

    func cloudWebSocketURL(cameraUID: String) -> URL? {
        URL(string: "wss://api.nanit.com/focus/cameras/\(cameraUID)/user_connect")
    }

    func localWebSocketURL(cameraIP: String) -> URL? {
        URL(string: "wss://\(cameraIP):442")
    }

    func climate(accessToken: String, cameraUID: String) async throws -> NanitClimateReading? {
        guard let url = cloudWebSocketURL(cameraUID: cameraUID) else {
            throw NanitAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "Nanit/767 CFNetwork/1498.700.2 Darwin/23.6.0",
            forHTTPHeaderField: "User-Agent"
        )

        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let requestID = Int32.random(in: 1...Int32.max)
        let payload = NanitSensorWebSocketCodec.sensorDataRequest(requestID: requestID)
        try await socket.send(.data(payload))

        for _ in 0..<6 {
            let message = try await Self.withTimeout(seconds: 12) {
                try await socket.receive()
            }

            guard case .data(let data) = message else {
                continue
            }

            if let reading = try NanitSensorWebSocketCodec.climateReading(
                from: data,
                matchingRequestID: requestID
            ) {
                return reading
            }
        }

        return nil
    }

    private func authRequest(body: [String: String]) async throws -> NanitTokens {
        var request = makeRequest(path: "/login", method: "POST")
        request.httpBody = try JSONEncoder().encode(body)

        let responseBody = try await decodedBody(for: request)

        if let mfaToken = responseBody["mfa_token"] as? String {
            throw NanitAPIError.mfaRequired(mfaToken)
        }

        if let message = extractErrorMessage(from: responseBody) {
            throw NanitAPIError.server(message)
        }

        guard let accessToken = responseBody["access_token"] as? String,
              let refreshToken = responseBody["refresh_token"] as? String
        else {
            throw NanitAPIError.invalidResponse
        }

        return NanitTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    private func decodeBabies(for request: URLRequest) async throws -> [NanitBaby] {
        let data = try await responseData(for: request)
        let decoder = JSONDecoder()

        do {
            if let babies = try? decoder.decode([NanitBaby].self, from: data) {
                NanightLog.info("Decoded \(babies.count) camera record(s) from top-level babies array")
                return babies
            }

            let decoded = try decoder.decode(BabiesResponse.self, from: data)
            NanightLog.info("Decoded \(decoded.babies.count) camera record(s) from babies response")
            return decoded.babies
        } catch {
            NanightLog.error("Failed to decode /babies response: \(Self.describeDecodingError(error))")
            NanightLog.info("Sanitized /babies payload preview: \(Self.sanitizedPayloadPreview(data))")
            throw error
        }
    }

    private func decodeMessages(for request: URLRequest, babyUID: String) async throws -> [NanitCloudEvent] {
        let data = try await responseData(for: request)
        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        return decoded.messages.map { $0.event(babyUID: babyUID) }
    }

    private func decodedBody(for request: URLRequest) async throws -> [String: Any] {
        let data = try await responseData(for: request, allowNanitMFAStatus: true)
        let body = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = body as? [String: Any] else {
            throw NanitAPIError.invalidResponse
        }
        return dictionary
    }

    private func responseData(
        for request: URLRequest,
        allowNanitMFAStatus: Bool = false
    ) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NanitAPIError.invalidResponse
            }

            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? "unknown"
            NanightLog.info("Nanit API \(method) \(path) -> HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 {
                throw NanitAPIError.invalidCredentials
            }

            if httpResponse.statusCode == 404, request.url?.path == "/tokens/refresh" {
                throw NanitAPIError.authExpired("Refresh token expired. Sign in again.")
            }

            if allowNanitMFAStatus, httpResponse.statusCode == 482 {
                return data
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = extractErrorMessage(from: body) {
                    throw NanitAPIError.server(message)
                }
                throw NanitAPIError.server("Nanit API returned HTTP \(httpResponse.statusCode).")
            }

            return data
        } catch let error as NanitAPIError {
            throw error
        } catch {
            throw NanitAPIError.transport(error.localizedDescription)
        }
    }

    private func makeRequest(path: String, method: String, accessToken: String? = nil) -> URLRequest {
        makeRequest(url: apiURL(path: path), method: method, accessToken: accessToken)
    }

    private func makeRequest(url: URL, method: String, accessToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "nanit-api-version")
        request.setValue(
            "Nanit/767 CFNetwork/1498.700.2 Darwin/23.6.0",
            forHTTPHeaderField: "User-Agent"
        )

        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func apiURL(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url!
    }

    private func extractErrorMessage(from body: [String: Any]) -> String? {
        if let error = body["error"] as? String {
            if let description = body["error_description"] as? String {
                return "\(error): \(description)"
            }
            return error
        }

        if body["access_token"] == nil, let message = body["message"] as? String {
            return message
        }

        return nil
    }

    private static func describeDecodingError(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case DecodingError.typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case DecodingError.valueNotFound(let type, let context):
            return "missing value for \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "data corrupted at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private static func codingPathDescription(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else {
            return "root"
        }

        return codingPath.map(\.stringValue).joined(separator: ".")
    }

    private static func sanitizedPayloadPreview(_ data: Data) -> String {
        let maxLength = 4_000
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 payload: \(data.count) bytes>"
        let redacted = raw
            .redactingJSONValuesForKeysContaining("token")
            .redactingJSONValue(for: "access_token")
            .redactingJSONValue(for: "refresh_token")
            .redactingJSONValue(for: "token")
            .redactingJSONValue(for: "authorization")
            .redactingJSONValue(for: "password")
            .redactingJSONValue(for: "email")

        guard redacted.count > maxLength else {
            return redacted
        }

        return "\(redacted.prefix(maxLength))... <truncated \(redacted.count - maxLength) chars>"
    }

    private static func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw NanitAPIError.transport("Nanit WebSocket request timed out.")
            }

            guard let result = try await group.next() else {
                throw NanitAPIError.invalidResponse
            }

            group.cancelAll()
            return result
        }
    }
}

enum NanitSensorWebSocketCodec {
    private static let messageTypeRequest: UInt64 = 1
    private static let messageTypeResponse: UInt64 = 2
    private static let requestTypeSensorData: UInt64 = 12
    private static let sensorTypeTemperature: UInt64 = 2
    private static let sensorTypeHumidity: UInt64 = 3

    static func sensorDataRequest(requestID: Int32) -> Data {
        var getSensorData = Data()
        getSensorData.appendVarintField(1, value: 1)

        var request = Data()
        request.appendVarintField(1, value: UInt64(requestID))
        request.appendVarintField(2, value: requestTypeSensorData)
        request.appendLengthDelimitedField(12, data: getSensorData)

        var message = Data()
        message.appendVarintField(1, value: messageTypeRequest)
        message.appendLengthDelimitedField(2, data: request)
        return message
    }

    static func climateReading(from data: Data, matchingRequestID requestID: Int32) throws -> NanitClimateReading? {
        var reader = NanitProtobufReader(data: data)
        var responseData: Data?
        var isResponse = false

        while let field = try reader.nextField() {
            if field.number == 1, field.varintValue == messageTypeResponse {
                isResponse = true
            } else if field.number == 3 {
                responseData = field.dataValue
            }
        }

        guard isResponse, let responseData else {
            return nil
        }

        var responseReader = NanitProtobufReader(data: responseData)
        var responseRequestID: Int32?
        var requestType: UInt64?
        var statusCode: UInt64?
        var temperatureCelsius: Double?
        var humidityPercent: Double?

        while let field = try responseReader.nextField() {
            switch field.number {
            case 1:
                responseRequestID = field.varintValue.flatMap { Int32(exactly: $0) }
            case 2:
                requestType = field.varintValue
            case 3:
                statusCode = field.varintValue
            case 9:
                guard let sensorData = field.dataValue else {
                    break
                }

                let sensor = try parseSensorData(sensorData)
                switch sensor.type {
                case sensorTypeTemperature:
                    temperatureCelsius = sensor.value
                case sensorTypeHumidity:
                    humidityPercent = sensor.value
                default:
                    break
                }
            default:
                break
            }
        }

        guard responseRequestID == requestID,
              requestType == requestTypeSensorData,
              statusCode == 0 || statusCode == 200
        else {
            return nil
        }

        guard temperatureCelsius != nil || humidityPercent != nil else {
            return nil
        }

        return NanitClimateReading(
            temperatureCelsius: temperatureCelsius,
            humidityPercent: humidityPercent
        )
    }

    private static func parseSensorData(_ data: Data) throws -> (type: UInt64, value: Double?) {
        var reader = NanitProtobufReader(data: data)
        var sensorType: UInt64?
        var value: Int64?
        var valueMilli: Int64?

        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                sensorType = field.varintValue
            case 3:
                value = field.varintValue.flatMap { Int64(exactly: $0) }
            case 6:
                valueMilli = field.varintValue.flatMap { Int64(exactly: $0) }
            default:
                break
            }
        }

        guard let sensorType else {
            throw NanitAPIError.invalidResponse
        }

        if let valueMilli {
            return (sensorType, Double(valueMilli) / 1000)
        }

        if let value {
            return (sensorType, Double(value))
        }

        return (sensorType, nil)
    }
}

private struct NanitProtobufField {
    let number: Int
    let wireType: Int
    let varintValue: UInt64?
    let dataValue: Data?
}

private struct NanitProtobufReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func nextField() throws -> NanitProtobufField? {
        guard offset < bytes.count else {
            return nil
        }

        let key = try readVarint()
        let number = Int(key >> 3)
        let wireType = Int(key & 0x7)

        switch wireType {
        case 0:
            return NanitProtobufField(
                number: number,
                wireType: wireType,
                varintValue: try readVarint(),
                dataValue: nil
            )
        case 1:
            try skip(byteCount: 8)
            return NanitProtobufField(number: number, wireType: wireType, varintValue: nil, dataValue: nil)
        case 2:
            let length = Int(try readVarint())
            let value = try readData(byteCount: length)
            return NanitProtobufField(number: number, wireType: wireType, varintValue: nil, dataValue: value)
        case 5:
            try skip(byteCount: 4)
            return NanitProtobufField(number: number, wireType: wireType, varintValue: nil, dataValue: nil)
        default:
            throw NanitAPIError.invalidResponse
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift

            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
        }

        throw NanitAPIError.invalidResponse
    }

    private mutating func readData(byteCount: Int) throws -> Data {
        guard byteCount >= 0, offset + byteCount <= bytes.count else {
            throw NanitAPIError.invalidResponse
        }

        let range = offset..<(offset + byteCount)
        offset += byteCount
        return Data(bytes[range])
    }

    private mutating func skip(byteCount: Int) throws {
        guard byteCount >= 0, offset + byteCount <= bytes.count else {
            throw NanitAPIError.invalidResponse
        }

        offset += byteCount
    }
}

private extension Data {
    mutating func appendVarintField(_ number: Int, value: UInt64) {
        appendVarint(UInt64(number << 3))
        appendVarint(value)
    }

    mutating func appendLengthDelimitedField(_ number: Int, data: Data) {
        appendVarint(UInt64(number << 3 | 2))
        appendVarint(UInt64(data.count))
        append(data)
    }

    mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        append(UInt8(remaining))
    }
}

private extension String {
    func redactingJSONValuesForKeysContaining(_ keyFragment: String) -> String {
        replacingOccurrences(
            of: "\"[^\"]*\(keyFragment)[^\"]*\"\\s*:\\s*\"[^\"]*\"",
            with: "\"<redacted_key>\":\"<redacted>\"",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    func redactingJSONValue(for key: String) -> String {
        replacingOccurrences(
            of: "\"\(key)\"\\s*:\\s*\"[^\"]*\"",
            with: "\"\(key)\":\"<redacted>\"",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

private struct BabiesResponse: Decodable {
    let babies: [NanitBaby]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        for key in ["babies", "children", "data"] {
            if let decoded = try container.decodeIfPresent([NanitBaby].self, for: key) {
                babies = decoded
                return
            }
        }

        if let keyedBabies = try container.decodeIfPresent([String: NanitBaby].self, for: "babies") {
            babies = Array(keyedBabies.values)
            return
        }

        throw DecodingError.keyNotFound(
            AnyCodingKey("babies"),
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected /babies response to contain babies, children, data, or a top-level array."
            )
        )
    }
}

private struct MessagesResponse: Decodable {
    let messages: [CloudMessage]
}

private struct CloudMessage: Decodable {
    let eventType: String
    let timestamp: TimeInterval

    enum CodingKeys: String, CodingKey {
        case eventType = "type"
        case timestamp = "time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(String.self, forKey: .eventType)

        if let value = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = value
        } else {
            let raw = try container.decode(String.self, forKey: .timestamp)
            if let value = Double(raw) {
                timestamp = value
            } else if let date = ISO8601DateFormatter().date(from: raw) {
                timestamp = date.timeIntervalSince1970
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timestamp,
                    in: container,
                    debugDescription: "Unsupported timestamp value \(raw)"
                )
            }
        }
    }

    func event(babyUID: String) -> NanitCloudEvent {
        NanitCloudEvent(eventType: eventType, timestamp: timestamp, babyUID: babyUID)
    }
}
