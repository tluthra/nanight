import AVKit
import Combine
import HaishinKit
import SwiftUI

struct NanightMenuView: View {
    @ObservedObject var model: NanightAppModel
    let videoInteraction: NanightVideoInteraction
    let takeScreenshot: @MainActor @Sendable () async throws -> URL
    var isFloating = false
    var toggleFloating: () -> Void = {}
    var toggleActivity: () -> Void = {}
    var openHistory: () -> Void = {}

    var body: some View {
        Group {
            switch model.connectionState {
            case .signedOut, .authExpired:
                LoginView(model: model)
                    .frame(width: 360)
                    .padding(16)
            case .mfaRequired:
                MFAView(model: model)
                    .frame(width: 360)
                    .padding(16)
            case .restoring:
                RestoringView()
                    .frame(width: 360)
                    .padding(16)
            case .signedIn, .offline:
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        MonitorView(model: model, videoInteraction: videoInteraction, takeScreenshot: takeScreenshot, isFloating: isFloating, toggleFloating: toggleFloating, toggleActivity: toggleActivity)
                        if model.activityExpanded {
                            Divider()
                            NanightHistoryView(model: model, compact: true, openHistory: openHistory)
                                .frame(height: model.activityPanelHeight - 1)
                        }
                    }
                    // Keep the camera at its natural height while AppKit animates the
                    // popover's bounds. Reveal the history below it instead of centering
                    // the taller stack inside each intermediate animation frame.
                    .fixedSize(horizontal: false, vertical: !isFloating)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .clipped()
                }
            }
        }
    }
}

private struct LoginView: View {
    @ObservedObject var model: NanightAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Nanit")
                .font(.title3.weight(.semibold))

            TextField("Email", text: $model.email)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $model.password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage = model.errorMessage {
                ErrorText(errorMessage)
            }

            Button {
                model.signIn()
            } label: {
                HStack {
                    if model.isBusy {
                        BusyGlyph()
                    }
                    Text(model.isBusy ? "Signing In" : "Sign In")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
        }
    }
}

private struct MFAView: View {
    @ObservedObject var model: NanightAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter MFA code")
                .font(.title3.weight(.semibold))

            TextField("Code", text: $model.mfaCode)
                .textFieldStyle(.roundedBorder)

            if let errorMessage = model.errorMessage {
                ErrorText(errorMessage)
            }

            HStack {
                Button("Back") {
                    model.connectionState = .signedOut
                }

                Spacer()

                Button {
                    model.completeMFA()
                } label: {
                    HStack {
                        if model.isBusy {
                            BusyGlyph()
                        }
                        Text("Verify")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
    }
}

private struct RestoringView: View {
    var body: some View {
        HStack(spacing: 10) {
            BusyGlyph()
            Text("Restoring Nanit session")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private struct BusyGlyph: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct MonitorView: View {
    @ObservedObject var model: NanightAppModel
    @ObservedObject var videoInteraction: NanightVideoInteraction
    let takeScreenshot: @MainActor @Sendable () async throws -> URL
    var isFloating = false
    var toggleFloating: () -> Void = {}
    var toggleActivity: () -> Void = {}
    @State private var isTakingScreenshot = false
    @State private var screenshotSaved = false
    @State private var screenshotFlash = false
    @State private var screenshotError: String?

    var body: some View {
        let viewportSize = videoInteraction.viewportSize

        GeometryReader { geometry in
            let size = geometry.size
            let fitScale = min(size.width / viewportSize.width, size.height / viewportSize.height)
            ZStack(alignment: .topLeading) {
                ZStack {
                    ZStack {
                        if let player = model.player {
                            PlayerSurface(player: player)
                        } else if let rtmpPlayer = model.rtmpPlayer {
                            RTMPPlayerSurface(player: rtmpPlayer)
                        } else {
                            PlaceholderVideoView(message: model.streamStatusText)
                        }
                    }
                    .frame(width: NanightVideoInteraction.surfaceSize.width, height: NanightVideoInteraction.surfaceSize.height)
                    .scaleEffect(videoInteraction.displayScale * fitScale)
                    .rotationEffect(.degrees(videoInteraction.rotationDegrees))
                    .offset(x: videoInteraction.offset.width * fitScale, y: videoInteraction.offset.height * fitScale)
                    .allowsHitTesting(false)
                }
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .clipped()

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.activeCamera?.name ?? "No camera")
                                .font(.headline.weight(.semibold))
                            if let rtmpPlayer = model.rtmpPlayer {
                                RTMPLiveStatusRow(player: rtmpPlayer, climate: model.climate)
                            } else {
                                LiveStatusRow(status: .live, climate: model.climate)
                            }
                            HStack(spacing: 10) {
                                ActivityIndicator(title: "Motion", systemName: "figure.walk", active: model.activity.motionActive, activeColor: .yellow)
                                ActivityIndicator(title: "Sound", systemName: "waveform", active: model.activity.soundActive, activeColor: .orange)
                                if let player = model.rtmpPlayer {
                                    BabyPresenceIndicator(detector: player.babyPresence)
                                }
                            }
                            .padding(.top, 3)
                        }
                        .foregroundStyle(.white)
                        .shadow(radius: 3)

                        Spacer()

                        if model.cameras.count > 1 {
                            Picker("Camera", selection: Binding(
                                get: { model.activeCamera?.uid ?? "" },
                                set: { model.selectCamera($0) }
                            )) {
                                ForEach(model.cameras) { camera in
                                    Text(camera.name).tag(camera.uid)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                    }

                    Spacer()

                    HStack(alignment: .bottom, spacing: 10) {
                        HStack(spacing: 10) {
                            OverlayButton(
                                systemName: model.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                help: model.isAudioMuted ? "Unmute audio" : "Mute audio",
                                foregroundColor: model.isAudioMuted ? .red : .white,
                                action: model.toggleAudio
                            )

                            TimelapseCameraControl(timelapse: model.timelapse, model: model,
                                                   screenshotSaved: screenshotSaved,
                                                   isTakingScreenshot: isTakingScreenshot,
                                                   saveScreenshot: saveScreenshot)
                        }

                        Spacer()

                        OverlayButton(
                            systemName: "chart.bar.xaxis",
                            help: model.activityExpanded ? "Hide activity" : "Show activity",
                            isSelected: model.activityExpanded,
                            action: toggleActivity
                        )
                        .accessibilityLabel(model.activityExpanded ? "Hide activity" : "Show activity")

                        OverlayButton(
                            systemName: isFloating ? "pin.fill" : "pin",
                            help: isFloating ? "Unpin window" : "Pin window",
                            isSelected: isFloating,
                            action: toggleFloating
                        )
                        .accessibilityLabel(isFloating ? "Unpin window" : "Pin window")
                    }
                }
                .padding(14)

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.58))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .frame(width: isFloating ? nil : viewportSize.width, height: isFloating ? nil : viewportSize.height)
        // Fill the hosting view throughout AppKit's resize, including the safe
        // area at the popover edge. The popover supplies the outer corner shape.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .overlay {
            Color.white.opacity(screenshotFlash ? 0.7 : 0)
                .allowsHitTesting(false)
        }
        .alert("Couldn’t save screenshot", isPresented: Binding(
            get: { screenshotError != nil },
            set: { if !$0 { screenshotError = nil } }
        )) {
            Button("OK", role: .cancel) { screenshotError = nil }
        } message: {
            Text(screenshotError ?? "")
        }
        .onAppear {
            NanightLog.gesture("VIEW appeared \(videoInteraction.diagnosticDescription)")
        }
        .onChange(of: videoInteraction.diagnosticDescription) { description in
            NanightLog.gesture("VIEW observed \(description)")
        }
    }

    private func saveScreenshot() {
        guard !isTakingScreenshot else { return }
        isTakingScreenshot = true
        Task { @MainActor in
            defer { isTakingScreenshot = false }
            do {
                _ = try await takeScreenshot()
                screenshotSaved = true
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    screenshotFlash = true
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { screenshotFlash = false }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                screenshotSaved = false
            } catch {
                screenshotError = error.localizedDescription
            }
        }
    }
}

private struct TimelapseCameraControl: View {
    @ObservedObject var timelapse: NanightTimelapse
    let model: NanightAppModel
    let screenshotSaved: Bool
    let isTakingScreenshot: Bool
    let saveScreenshot: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if timelapse.state == .exporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.42), in: Circle())
                    .help("Creating timelapse video…")
                    .accessibilityLabel("Creating timelapse video")
            } else {
                OverlayButton(
                    systemName: timelapse.state == .recording ? "timelapse" :
                        (timelapse.state == .saved || screenshotSaved ? "checkmark" : "camera.fill"),
                    help: timelapse.state == .recording ? "Stop timelapse and create video" :
                        (timelapse.state == .saved ? "Timelapse saved to Downloads" : "Save screenshot to Downloads"),
                    foregroundColor: timelapse.state == .recording ? .red : .white,
                    action: {
                        if timelapse.state == .recording { timelapse.stop() }
                        else { saveScreenshot() }
                    }
                )
                .disabled(isTakingScreenshot)
                .contextMenu {
                    if timelapse.state == .idle || timelapse.state == .saved {
                        Button("Start Timelapse") { timelapse.start(model: model) }
                    }
                }
            }
            if hovering && timelapse.state == .idle {
                OverlayButton(
                    systemName: "timelapse",
                    help: "Start timelapse: capture a photo every 5 seconds",
                    action: { timelapse.start(model: model) }
                )
                .accessibilityLabel("Start timelapse")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .clipped()
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hovering)
        .alert("Timelapse", isPresented: Binding(
            get: { timelapse.errorMessage != nil },
            set: { if !$0 { timelapse.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { timelapse.errorMessage = nil }
        } message: {
            Text(timelapse.errorMessage ?? "")
        }
    }
}

private struct RTMPLiveStatusRow: View {
    @ObservedObject var player: NanightRTMPPlayer
    let climate: NanitClimateReading?

    var body: some View {
        LiveStatusRow(
            status: player.videoFrameState,
            climate: climate
        )
    }
}

private struct LiveStatusRow: View {
    let status: NanightVideoFrameState
    let climate: NanitClimateReading?

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(status == .live ? .red : .yellow)
                    .frame(width: 6, height: 6)

                Text(statusText)

                Text(formatter.string(from: context.date))
                    .monospacedDigit()

                if let temperature = temperatureText {
                    Text("•")
                    Text(temperature)
                        .monospacedDigit()
                }

                if let humidity = humidityText {
                    Text("•")
                    Text(humidity)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var statusText: String {
        switch status {
        case .waitingForFrames:
            return "Connecting"
        case .live:
            return "Live"
        case .stalled:
            return "Stalled"
        }
    }

    private var temperatureText: String? {
        guard let temperatureCelsius = climate?.temperatureCelsius else {
            return nil
        }

        if Locale.current.measurementSystem == .us {
            let fahrenheit = temperatureCelsius * 9 / 5 + 32
            return "\(Int(fahrenheit.rounded()))°F"
        }

        return "\(Int(temperatureCelsius.rounded()))°C"
    }

    private var humidityText: String? {
        guard let humidityPercent = climate?.humidityPercent else {
            return nil
        }

        return "\(Int(humidityPercent.rounded()))%"
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .minimal
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct RTMPPlayerSurface: View {
    @ObservedObject var player: NanightRTMPPlayer

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PiPHKViewRepresentable(previewSource: player, videoGravity: .resize)
                .background(Color.black)

            if player.lastErrorMessage != nil || player.readyStateText == "RTMPS playback failed" {
                Text(player.lastErrorMessage ?? player.readyStateText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(10)
            }
        }
    }
}

private struct PlaceholderVideoView: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "video.slash")
                    .font(.system(size: 26, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }
            .foregroundStyle(.white.opacity(0.82))
        }
    }
}

private struct ActivityIndicator: View {
    let title: String
    let systemName: String
    let active: Bool
    let activeColor: Color

    var body: some View {
        Label(title, systemImage: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(active ? activeColor : .white.opacity(0.45))
            .help(active ? "\(title) detected" : "No \(title.lowercased()) detected")
            .accessibilityLabel("\(title): \(active ? "detected" : "not detected")")
    }
}

private struct OverlayButton: View {
    let systemName: String
    let help: String
    var foregroundColor: Color = .white
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 30)
                .background(isSelected ? Color.blue : Color.black.opacity(0.42))
                .clipShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DisclaimerView: View {
    var body: some View {
        Text("Unofficial and not affiliated with Nanit.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @ObservedObject var model: NanightAppModel
    @ObservedObject var updater: NanightUpdater
    @State private var confirmClearHistory = false

    var body: some View {
        Form {
            Section("Account") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(model.statusLabel)
                        .foregroundStyle(.secondary)
                }

                Picker("Selected camera", selection: Binding(
                    get: { model.activeCamera?.uid ?? "" },
                    set: { model.selectCamera($0) }
                )) {
                    if model.cameras.isEmpty {
                        Text("No cameras").tag("")
                    }
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(camera.uid)
                    }
                }

                HStack {
                    Button("Refresh Cameras") {
                        Task {
                            await model.refreshCameras()
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        model.signOut()
                    }
                }
            }

            Section("Monitoring") {
                Toggle("Start monitoring on launch", isOn: $model.settings.startMonitoringOnLaunch)
                Toggle("Motion menu bar state", isOn: $model.settings.motionMenuBarStateEnabled)
                Toggle("Sound menu bar state", isOn: $model.settings.soundMenuBarStateEnabled)

                HStack {
                    Text("Motion indicator duration")
                    Spacer()
                    Text("10 seconds")
                        .foregroundStyle(.secondary)
                }
                Text("Motion clears automatically 10 seconds after a new motion event is detected. Each new event restarts the timer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Recent activity window")
                    Slider(value: $model.settings.eventActiveWindowSeconds, in: 30...600, step: 30)
                    Text("\(Int(model.settings.eventActiveWindowSeconds))s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Text("Only events within this window count as recent activity. Sound stays active for this long after its latest event; motion uses the separate 10-second timer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Notifications") {
                Toggle("Notifications", isOn: Binding(
                    get: { model.settings.notificationsEnabled },
                    set: { enabled in
                        if enabled {
                            model.requestNotificationPermission()
                        } else {
                            model.settings.notificationsEnabled = false
                        }
                    }
                ))
                Toggle("Motion", isOn: $model.settings.notifyOnMotion)
                Toggle("Sound", isOn: $model.settings.notifyOnSound)

                HStack {
                    Text("Notification cooldown")
                    Slider(value: $model.settings.notificationCooldownSeconds, in: 30...600, step: 30)
                    Text("\(Int(model.settings.notificationCooldownSeconds))s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Text("Minimum time between notifications of the same type. This does not change how long activity indicators stay active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Comfort Range") {
                HStack {
                    Text("Temperature")
                    Spacer()
                    TextField("Low", value: $model.settings.comfortableTemperatureLowC, format: .number)
                        .frame(width: 58)
                    Text("to")
                        .foregroundStyle(.secondary)
                    TextField("High", value: $model.settings.comfortableTemperatureHighC, format: .number)
                        .frame(width: 58)
                    Text("C")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Humidity")
                    Spacer()
                    TextField("Low", value: $model.settings.comfortableHumidityLow, format: .number)
                        .frame(width: 58)
                    Text("to")
                        .foregroundStyle(.secondary)
                    TextField("High", value: $model.settings.comfortableHumidityHigh, format: .number)
                        .frame(width: 58)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Activity history") {
                Text("Activity is stored only on this Mac and kept indefinitely. No video or audio is recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear history…", role: .destructive) { confirmClearHistory = true }
                if let error = model.historyError { Text(error).font(.caption).foregroundStyle(.red) }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                CheckForUpdatesButton(updater: updater)
                Text("Updates install only when you choose to install and relaunch Nanight.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Copy Diagnostics") {
                    model.copyDiagnosticsToPasteboard()
                }

                ForEach(NanitAPIClient.protocolReferences) { reference in
                    Link(reference.title, destination: reference.url)
                }
            }
        }
        .alert("Clear all activity history?", isPresented: $confirmClearHistory) {
            Button("Cancel", role: .cancel) {}
            Button("Clear history", role: .destructive) { Task { await model.clearActivityHistory() } }
        } message: {
            Text("This permanently deletes saved activity for every camera on this Mac. New activity will continue to be recorded.")
        }
        .formStyle(.grouped)
        .tint(.accentColor)
        .padding()
        .frame(width: 520, height: 620)
    }
}

private struct BabyPresenceIndicator: View {
    @ObservedObject var detector: NanightBabyPresence

    var body: some View {
        HStack(spacing: 10) {
            ActivityIndicator(title: "In bed", systemName: "figure.child", active: detector.possibleBaby, activeColor: .mint)
                .help("Local baby-presence estimate. Brief missed detections are smoothed.")
            ActivityIndicator(title: "Sleeping", systemName: "moon.zzz.fill", active: detector.likelySleeping, activeColor: .cyan)
                .help("Estimated from presence and sustained low image movement. Faded means sleep is unconfirmed, not necessarily awake.")
                .accessibilityLabel("Sleeping: \(detector.likelySleeping ? "likely asleep" : "unconfirmed")")
        }
    }
}
