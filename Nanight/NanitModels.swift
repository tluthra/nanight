import Foundation

struct NanitTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let issuedAt: Date

    init(accessToken: String, refreshToken: String, issuedAt: Date = Date()) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.issuedAt = issuedAt
    }

    var shouldRefresh: Bool {
        Date().timeIntervalSince(issuedAt) > 50 * 60
    }
}

struct NanitNetworkInfo: Codable, Equatable, Hashable {
    let ssid: String?
    let frequencyMHz: Int?
    let signalDBM: Int?

    enum CodingKeys: String, CodingKey {
        case ssid
        case frequencyMHz = "freq"
        case signalDBM = "level"
    }
}

struct NanitBaby: Decodable, Identifiable, Hashable {
    let uid: String
    let name: String
    let cameraUID: String
    let speakerUID: String?
    let network: NanitNetworkInfo?

    var id: String { uid }

    init(
        uid: String,
        name: String,
        cameraUID: String,
        speakerUID: String? = nil,
        network: NanitNetworkInfo? = nil
    ) {
        self.uid = uid
        self.name = name
        self.cameraUID = cameraUID
        self.speakerUID = speakerUID
        self.network = network
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        uid = try container.requiredString(for: ["uid", "baby_uid", "id"], label: "Nanit baby UID")

        let rawName = container.string(for: ["name", "display_name", "first_name"]) ?? "Nursery"
        name = rawName.nanitSanitizedName

        let topLevelCameraUID = container.string(for: ["camera_uid", "camera_id"])
        var nestedCameraUID: String?
        var nestedNetwork: NanitNetworkInfo?

        if let camera = try container.nestedContainerIfPresent(for: "camera") {
            nestedCameraUID = camera.string(for: ["uid", "id", "uuid", "camera_uid", "camera_id"])
            nestedNetwork = try camera.decodeIfPresent(NanitNetworkInfo.self, for: "network")
        }

        cameraUID = topLevelCameraUID ?? nestedCameraUID ?? uid
        network = nestedNetwork

        if let speakerContainer = try container.nestedContainerIfPresent(for: "speaker") {
            let directUID = speakerContainer.string(for: ["uid", "id", "speaker_uid", "speaker_id"])
            let nestedSpeaker = try speakerContainer.nestedContainerIfPresent(for: "speaker")
            speakerUID = directUID ?? nestedSpeaker?.string(for: ["uid", "id", "speaker_uid", "speaker_id"])
        } else {
            speakerUID = nil
        }
    }
}

struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func string(for keys: [String]) -> String? {
        for key in keys {
            let codingKey = AnyCodingKey(key)
            if let value = try? decodeIfPresent(String.self, forKey: codingKey), !value.isEmpty {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: codingKey) {
                return "\(value)"
            }
        }

        return nil
    }

    func requiredString(for keys: [String], label: String) throws -> String {
        if let value = string(for: keys) {
            return value
        }

        throw DecodingError.keyNotFound(
            AnyCodingKey(keys.first ?? label),
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Missing \(label). Tried keys: \(keys.joined(separator: ", "))"
            )
        )
    }

    func nestedContainerIfPresent(for key: String) throws -> KeyedDecodingContainer<AnyCodingKey>? {
        let codingKey = AnyCodingKey(key)
        guard contains(codingKey) else {
            return nil
        }

        if (try? decodeNil(forKey: codingKey)) == true {
            return nil
        }

        return try nestedContainer(keyedBy: AnyCodingKey.self, forKey: codingKey)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        try decodeIfPresent(type, forKey: AnyCodingKey(key))
    }
}

struct NanitCloudEvent: Decodable, Identifiable, Hashable {
    let eventType: String
    let timestamp: TimeInterval
    let babyUID: String

    var id: String {
        "\(babyUID)-\(eventType)-\(timestamp)"
    }

    enum CodingKeys: String, CodingKey {
        case eventType = "type"
        case timestamp = "time"
    }

    init(eventType: String, timestamp: TimeInterval, babyUID: String) {
        self.eventType = eventType
        self.timestamp = timestamp
        self.babyUID = babyUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(String.self, forKey: .eventType)
        timestamp = try Self.decodeTimestamp(from: container, key: .timestamp)
        babyUID = ""
    }

    init(from decoder: Decoder, babyUID: String) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(String.self, forKey: .eventType)
        timestamp = try Self.decodeTimestamp(from: container, key: .timestamp)
        self.babyUID = babyUID
    }

    private static func decodeTimestamp<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws -> TimeInterval {
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }

        let raw = try container.decode(String.self, forKey: key)
        if let value = Double(raw) {
            return value
        }

        if let date = ISO8601DateFormatter().date(from: raw) {
            return date.timeIntervalSince1970
        }

        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Unsupported timestamp value \(raw)"
        )
    }
}

struct NurseryActivity: Equatable {
    var motionActive: Bool = false
    var soundActive: Bool = false
    var lastMotionAt: Date?
    var lastSoundAt: Date?

    static func current(
        from events: [  ],
        now: Date = Date(),
        activeWindow: TimeInterval
    ) -> NurseryActivity {
        var activity = NurseryActivity()
        let cutoff = now.timeIntervalSince1970 - activeWindow

        for event in events {
            let type = event.eventType.uppercased()
            guard event.timestamp >= cutoff else {
                continue
            }

            if type == "MOTION" {
                activity.motionActive = true
                activity.lastMotionAt = maxDate(activity.lastMotionAt, Date(timeIntervalSince1970: event.timestamp))
            }

            if type == "SOUND" {
                activity.soundActive = true
                activity.lastSoundAt = maxDate(activity.lastSoundAt, Date(timeIntervalSince1970: event.timestamp))
            }
        }

        return activity
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else {
            return rhs
        }
        return max(lhs, rhs)
    }
}

struct NanitClimateReading: Equatable {
    let temperatureCelsius: Double?
    let humidityPercent: Double?
    let updatedAt: Date

    init(
        temperatureCelsius: Double?,
        humidityPercent: Double?,
        updatedAt: Date = Date()
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.updatedAt = updatedAt
    }
}

enum NanitConnectionState: Equatable {
    case signedOut
    case restoring
    case signedIn
    case mfaRequired
    case offline(String)
    case authExpired(String)
}

struct NanitUserSettings: Codable, Equatable {
    var selectedBabyUID: String?
    var startMonitoringOnLaunch: Bool = true
    var backgroundAudioEnabled: Bool = false
    var startMuted: Bool = false
    var notificationsEnabled: Bool = false
    var notifyOnMotion: Bool = true
    var notifyOnSound: Bool = true
    var notifyOnOffline: Bool = true
    var notificationCooldownSeconds: Double = 120
    var eventActiveWindowSeconds: Double = 300
    var motionMenuBarStateEnabled: Bool = true
    var soundMenuBarStateEnabled: Bool = true
    var comfortableTemperatureLowC: Double = 18
    var comfortableTemperatureHighC: Double = 24
    var comfortableHumidityLow: Double = 30
    var comfortableHumidityHigh: Double = 60

    static let storageKey = "NanightUserSettings"

    static func load(from defaults: UserDefaults = .standard) -> NanitUserSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(NanitUserSettings.self, from: data)
        else {
            return NanitUserSettings()
        }

        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }

        defaults.set(data, forKey: Self.storageKey)
    }
}

extension String {
    var nanitSanitizedName: String {
        let withoutTags = replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        return withoutTags
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
