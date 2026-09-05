import CoreMedia
import Foundation
import Testing
@testable import Nanight

@MainActor
struct NanightTests {
    @Test func decodesBabyFromModernNanitShape() throws {
        let data = Data(
            """
            {
              "uid": "baby-1",
              "name": "<b>Nursery</b>",
              "camera_uid": "camera-1",
              "camera": {
                "network": {
                  "ssid": "home",
                  "freq": 5240,
                  "level": -61
                }
              },
              "speaker": {
                "speaker": {
                  "uid": "speaker-1"
                }
              }
            }
            """.utf8
        )

        let baby = try JSONDecoder().decode(NanitBaby.self, from: data)

        #expect(baby.uid == "baby-1")
        #expect(baby.name == "Nursery")
        #expect(baby.cameraUID == "camera-1")
        #expect(baby.speakerUID == "speaker-1")
        #expect(baby.network?.signalDBM == -61)
    }

    @Test func decodesBabyFromNestedCameraShape() throws {
        let data = Data(
            """
            {
              "uid": "baby-2",
              "name": "Nap Room",
              "camera": {
                "uid": "camera-2"
              }
            }
            """.utf8
        )

        let baby = try JSONDecoder().decode(NanitBaby.self, from: data)

        #expect(baby.cameraUID == "camera-2")
        #expect(baby.speakerUID == nil)
    }

    @Test func decodesBabyFromAlternateNanitKeys() throws {
        let data = Data(
            """
            {
              "baby_uid": "baby-3",
              "display_name": "Crib",
              "camera": {
                "id": "camera-3"
              },
              "speaker": {
                "id": "speaker-3"
              }
            }
            """.utf8
        )

        let baby = try JSONDecoder().decode(NanitBaby.self, from: data)

        #expect(baby.uid == "baby-3")
        #expect(baby.name == "Crib")
        #expect(baby.cameraUID == "camera-3")
        #expect(baby.speakerUID == "speaker-3")
    }

    @Test func decodesBabyWhenNestedSpeakerIsNull() throws {
        let data = Data(
            """
            {
              "uid": "baby-4",
              "name": "Nursery",
              "camera_uid": "camera-4",
              "speaker": {
                "speaker": null
              }
            }
            """.utf8
        )

        let baby = try JSONDecoder().decode(NanitBaby.self, from: data)

        #expect(baby.uid == "baby-4")
        #expect(baby.cameraUID == "camera-4")
        #expect(baby.speakerUID == nil)
    }

    @Test func activityWindowDetectsAndDecaysMotionAndSound() {
        let now = Date(timeIntervalSince1970: 1_000)
        let events = [
            NanitCloudEvent(eventType: "MOTION", timestamp: 980, babyUID: "baby-1"),
            NanitCloudEvent(eventType: "SOUND", timestamp: 700, babyUID: "baby-1")
        ]

        let activity = NurseryActivity.current(from: events, now: now, activeWindow: 60)

        #expect(activity.motionActive)
        #expect(!activity.soundActive)
        #expect(activity.lastMotionAt == Date(timeIntervalSince1970: 980))
    }

    @Test func buildsRTMPSStreamURL() {
        let client = NanitAPIClient()
        let url = client.rtmpsStreamURL(babyUID: "baby-1", accessToken: "token.abc")

        #expect(url?.absoluteString == "rtmps://media-secured.nanit.com/nanit/baby-1.token.abc")
    }

    @Test func parsesClimateSensorDataResponse() throws {
        let data = sensorDataResponse(requestID: 7, temperatureMilli: 22_300, humidityMilli: 45_500)

        let reading = try NanitSensorWebSocketCodec.climateReading(from: data, matchingRequestID: 7)

        #expect(reading?.temperatureCelsius == 22.3)
        #expect(reading?.humidityPercent == 45.5)
    }

    @Test func videoFrameLivenessRequiresFreshDistinctFrames() {
        var tracker = NanightVideoFrameTracker(staleAfter: 3)
        let firstFrame = CMTime(value: 1, timescale: 10)
        let secondFrame = CMTime(value: 2, timescale: 10)

        #expect(tracker.state(at: 100) == .waitingForFrames)

        tracker.recordFrame(presentationTimeStamp: firstFrame, at: 100)
        #expect(tracker.state(at: 100) == .waitingForFrames)

        tracker.recordFrame(presentationTimeStamp: firstFrame, at: 101)
        #expect(tracker.state(at: 101) == .waitingForFrames)

        tracker.recordFrame(presentationTimeStamp: secondFrame, at: 101)
        #expect(tracker.state(at: 101) == .live)
        #expect(tracker.state(at: 104.1) == .stalled)
    }

    @Test func videoFrameLivenessStallsWhenNoInitialFramesArrive() {
        var tracker = NanightVideoFrameTracker(staleAfter: 3, initialFrameTimeout: 10)

        tracker.startMonitoring(at: 100)

        #expect(tracker.state(at: 110) == .waitingForFrames)
        #expect(tracker.state(at: 110.1) == .stalled)
    }

    @Test func videoFrameLivenessRequiresTwoFreshFramesToRecover() {
        var tracker = NanightVideoFrameTracker(staleAfter: 3)

        tracker.recordFrame(presentationTimeStamp: CMTime(value: 1, timescale: 10), at: 100)
        tracker.recordFrame(presentationTimeStamp: CMTime(value: 2, timescale: 10), at: 100.1)
        #expect(tracker.state(at: 104) == .stalled)

        tracker.recordFrame(presentationTimeStamp: CMTime(value: 3, timescale: 10), at: 104)
        #expect(tracker.state(at: 104) == .stalled)

        tracker.recordFrame(presentationTimeStamp: CMTime(value: 4, timescale: 10), at: 104.1)
        #expect(tracker.state(at: 104.1) == .live)
    }

    @Test func automaticReconnectPolicyBacksOffAndCapsItsDelay() {
        #expect(NanightAutomaticReconnectPolicy.delay(forAttempt: 0) == 1)
        #expect(NanightAutomaticReconnectPolicy.delay(forAttempt: 1) == 2)
        #expect(NanightAutomaticReconnectPolicy.delay(forAttempt: 2) == 4)
        #expect(NanightAutomaticReconnectPolicy.delay(forAttempt: 5) == 30)
        #expect(NanightAutomaticReconnectPolicy.delay(forAttempt: 20) == 30)
        #expect(
            NanightAutomaticReconnectPolicy.delay(
                forAttempt: 0,
                secondsSinceLastReconnect: 4
            ) == 6
        )
        #expect(NanightAutomaticReconnectPolicy.nextAttempt(after: 5) == 5)
    }

    private func sensorDataResponse(
        requestID: Int32,
        temperatureMilli: UInt64,
        humidityMilli: UInt64
    ) -> Data {
        var temperature = Data()
        temperature.appendVarintFieldForTest(1, value: 2)
        temperature.appendVarintFieldForTest(6, value: temperatureMilli)

        var humidity = Data()
        humidity.appendVarintFieldForTest(1, value: 3)
        humidity.appendVarintFieldForTest(6, value: humidityMilli)

        var response = Data()
        response.appendVarintFieldForTest(1, value: UInt64(requestID))
        response.appendVarintFieldForTest(2, value: 12)
        response.appendVarintFieldForTest(3, value: 0)
        response.appendLengthDelimitedFieldForTest(9, data: temperature)
        response.appendLengthDelimitedFieldForTest(9, data: humidity)

        var message = Data()
        message.appendVarintFieldForTest(1, value: 2)
        message.appendLengthDelimitedFieldForTest(3, data: response)
        return message
    }
}

private extension Data {
    mutating func appendVarintFieldForTest(_ number: Int, value: UInt64) {
        appendVarintForTest(UInt64(number << 3))
        appendVarintForTest(value)
    }

    mutating func appendLengthDelimitedFieldForTest(_ number: Int, data: Data) {
        appendVarintForTest(UInt64(number << 3 | 2))
        appendVarintForTest(UInt64(data.count))
        append(data)
    }

    mutating func appendVarintForTest(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        append(UInt8(remaining))
    }
}
