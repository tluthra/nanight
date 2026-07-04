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
}
