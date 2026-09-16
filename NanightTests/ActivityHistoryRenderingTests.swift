import AppKit
import SwiftUI
import Testing
@testable import Nanight

@MainActor
struct ActivityHistoryRenderingTests {
    @Test func insertingActivityDoesNotResizeTheCameraHostBeforeAnimation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = NanightAppModel(api: NanitAPIClient(), keychain: KeychainTokenStore(), notifications: NanitNotificationController(), activityStore: NanightActivityStore(url: folder.appendingPathComponent("history.sqlite")))
        model.connectionState = .signedIn
        let interaction = NanightVideoInteraction()
        let host = NanightCameraHostingController(rootView: NanightMenuView(model: model, videoInteraction: interaction, takeScreenshot: { throw NanightScreenshotError.imageUnavailable }))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(interaction.viewportSize)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let frame = window.frame
        let bounds = host.view.bounds
        let fittingSize = host.view.fittingSize
        // Exercise the actual state insertion without an outer fixed-size wrapper.
        // AppKit has not yet been asked to grow the container at this point.
        model.activityExpanded = true
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutSubtreeIfNeeded()
            #expect(window.frame == frame)
            #expect(host.view.bounds == bounds)
            #expect(host.view.fittingSize == fittingSize)
        }
        window.setContentSize(NSSize(width: 520, height: 532))
        model.activityExpanded = false
        let expandedFrame = window.frame
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(16))
            host.view.layoutSubtreeIfNeeded()
            #expect(window.frame == expandedFrame)
        }
    }

    @Test func cameraRemainsStationaryAtIntermediateExpansionHeights() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = NanightAppModel(api: NanitAPIClient(), keychain: KeychainTokenStore(), notifications: NanitNotificationController(), activityStore: NanightActivityStore(url: folder.appendingPathComponent("history.sqlite")))
        model.cameras = [NanitBaby(uid: "preview", name: "Nursery", cameraUID: "preview")]
        model.connectionState = .signedIn
        model.activityExpanded = true
        let interaction = NanightVideoInteraction()
        var reference: Data?
        for height in [292.0, 322, 412, 532] {
            let view = NanightMenuView(model: model, videoInteraction: interaction, takeScreenshot: { throw NanightScreenshotError.imageUnavailable })
                .frame(width: 520, height: height, alignment: .top).clipped()
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 520, height: height))
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            let scale = CGFloat(image.width) / 520
            let camera = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int(292 * scale))))
            let png = try #require(NSBitmapImageRep(cgImage: camera).representation(using: .png, properties: [:]))
            if let reference { #expect(png == reference, "Camera moved at intermediate height \(height)") }
            else { reference = png }
            window.orderOut(nil)
        }
    }

    @Test func historyFitsNativeWindowAndCompactPanel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NanightHistoryPreview-\(UUID().uuidString)")
        let store = NanightActivityStore(url: folder.appendingPathComponent("history.sqlite"))
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let session = UUID()
        for offset in stride(from: 0.0, through: min(now.timeIntervalSince(start), 6 * 3600), by: 30) {
            let time = start.addingTimeInterval(offset)
            let events = Int(offset) % 2700 == 0 ? [NanightHistoryEvent(timestamp: time, kind: "MOTION")] : []
            try await store.record(camera: "preview", events: events, at: time, session: session)
        }
        for offset in stride(from: 3600.0, through: 5 * 3600, by: 3) {
            _ = try await store.recordSignal(camera: "preview", observation: NanightSignalObservation(
                timestamp: start.addingTimeInterval(offset), session: session, kind: .sample,
                babySimilarity: 0.3, emptySimilarity: 0.2, changedFraction: 0,
                brightnessChange: 0, motionValid: true))
        }
        let model = NanightAppModel(api: NanitAPIClient(), keychain: KeychainTokenStore(), notifications: NanitNotificationController(), activityStore: store)
        model.cameras = [NanitBaby(uid: "preview", name: "Nursery", cameraUID: "preview")]
        model.connectionState = .signedIn
        for (name, compact, size, appearance) in [
            ("window-light", false, NSSize(width: 780, height: 620), NSAppearance.Name.aqua),
            ("panel-dark", true, NSSize(width: 360, height: 240), NSAppearance.Name.darkAqua),
            ("panel-portrait", true, NSSize(width: 292, height: 240), NSAppearance.Name.aqua)
        ] {
            let host = NSHostingController(rootView: NanightHistoryView(model: model, compact: compact))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(350))
            if !compact {
                model.selectedHistoryDay = start
                try await Task.sleep(for: .milliseconds(100))
            }
            host.view.layoutSubtreeIfNeeded()
            #expect(host.view.bounds.width == size.width)
            #expect(host.view.bounds.height == size.height)
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = folder.appendingPathComponent("\(name).png")
            try png.write(to: output)
            print("HISTORY_PREVIEW \(output.path)")
            window.orderOut(nil)
        }
    }
}
