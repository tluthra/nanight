import AVKit
import HaishinKit
import SwiftUI

struct NanightMenuView: View {
    @ObservedObject var model: NanightAppModel

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
                MonitorView(model: model)
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
    private let sourceVideoSize = CGSize(width: 520, height: 292)

    var body: some View {
        let viewportSize = model.videoViewportSize

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
                .frame(width: sourceVideoSize.width, height: sourceVideoSize.height)
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .background(Color.black)
            .clipped()

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.activeCamera?.name ?? "No camera")
                            .font(.headline.weight(.semibold))
                        if let rtmpPlayer = model.rtmpPlayer {
                            RTMPLiveStatusRow(player: rtmpPlayer)
                        } else {
                            LiveStatusRow(isConnecting: false)
                        }
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

                HStack(spacing: 10) {
                    OverlayButton(
                        systemName: model.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        help: model.isAudioMuted ? "Unmute audio" : "Mute audio",
                        foregroundColor: model.isAudioMuted ? .red : .white,
                        action: model.toggleAudio
                    )

                    Spacer()

                    ActivityDot(systemName: "figure.walk.motion", active: model.activity.motionActive, activeColor: .yellow)
                    ActivityDot(systemName: "waveform", active: model.activity.soundActive, activeColor: .orange)
                    ActivityDot(systemName: "network", active: model.isAuthenticated, activeColor: .green)
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
        .frame(width: viewportSize.width, height: viewportSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct RTMPLiveStatusRow: View {
    @ObservedObject var player: NanightRTMPPlayer

    var body: some View {
        LiveStatusRow(isConnecting: player.readyStateText == "Connecting RTMPS stream")
    }
}

private struct LiveStatusRow: View {
    let isConnecting: Bool

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(isConnecting ? .yellow : .red)
                    .frame(width: 6, height: 6)

                Text(isConnecting ? "Connecting" : "Live")

                Text(formatter.string(from: context.date))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.78))
        }
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

private struct ActivityDot: View {
    let systemName: String
    let active: Bool
    let activeColor: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? .black : .white.opacity(0.7))
            .frame(width: 28, height: 28)
            .background(active ? activeColor : Color.black.opacity(0.38))
            .clipShape(Circle())
            .help(active ? "Active" : "Inactive")
    }
}

private struct OverlayButton: View {
    let systemName: String
    let help: String
    var foregroundColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.42))
                .clipShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(help)
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
                    Text("Activity window")
                    Slider(value: $model.settings.eventActiveWindowSeconds, in: 30...600, step: 30)
                    Text("\(Int(model.settings.eventActiveWindowSeconds))s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
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
                Toggle("Offline", isOn: $model.settings.notifyOnOffline)

                HStack {
                    Text("Cooldown")
                    Slider(value: $model.settings.notificationCooldownSeconds, in: 30...600, step: 30)
                    Text("\(Int(model.settings.notificationCooldownSeconds))s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
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

            Section("Diagnostics") {
                Button("Copy Diagnostics") {
                    model.copyDiagnosticsToPasteboard()
                }

                ForEach(NanitAPIClient.protocolReferences) { reference in
                    Link(reference.title, destination: reference.url)
                }
            }
        }
        .formStyle(.grouped)
        .tint(.accentColor)
        .padding()
        .frame(width: 520, height: 620)
    }
}
