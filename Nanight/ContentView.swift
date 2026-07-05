import AVKit
import HaishinKit
import SwiftUI

struct NanightMenuView: View {
    @ObservedObject var model: NanightAppModel
    var onVideoViewportChange: (() -> Void)?

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
                MonitorView(
                    model: model,
                    onVideoViewportChange: onVideoViewportChange
                )
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
    let onVideoViewportChange: (() -> Void)?
    @State private var gestureRotationDegrees: Double = 0
    private let sourceVideoSize = CGSize(width: 520, height: 292)
    private let rotationAnimation = Animation.interpolatingSpring(stiffness: 220, damping: 24)

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
                .rotationEffect(.degrees(model.videoRotationDegrees + gestureRotationDegrees))
                .scaleEffect(model.videoZoomScale)
                .offset(model.videoPanOffset)
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .background(Color.black)
            .clipped()
            .overlay {
                VideoGestureSurface(
                    onMagnify: model.zoomVideo,
                    onPan: model.panVideo,
                    onRotateChanged: { degrees in
                        gestureRotationDegrees = Double(-degrees)
                    },
                    onRotateEnded: { degrees in
                        let targetDegrees = model.videoRotationDegrees + Double(-degrees)
                        let targetQuarterTurns = Int((targetDegrees / 90).rounded())

                        withAnimation(rotationAnimation) {
                            model.setVideoRotationQuarterTurns(targetQuarterTurns)
                            gestureRotationDegrees = 0
                        }
                        onVideoViewportChange?()
                    }
                )
            }
            .animation(rotationAnimation, value: model.videoRotationQuarterTurns)

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.activeCamera?.name ?? "No camera")
                            .font(.headline.weight(.semibold))
                        LiveStatusRow()
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
        .animation(rotationAnimation, value: model.videoRotationQuarterTurns)
    }
}

private struct VideoGestureSurface: NSViewRepresentable {
    let onMagnify: (CGFloat) -> Void
    let onPan: (CGSize) -> Void
    let onRotateChanged: (CGFloat) -> Void
    let onRotateEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VideoGestureNSView {
        let view = VideoGestureNSView()
        view.onMagnify = onMagnify
        view.onPan = onPan
        view.onRotateChanged = onRotateChanged
        view.onRotateEnded = onRotateEnded
        NanightLog.info("VideoGestureSurface makeNSView view=\(view.debugID)")
        context.coordinator.installGestureRecognizers(on: view)
        return view
    }

    func updateNSView(_ nsView: VideoGestureNSView, context: Context) {
        nsView.onMagnify = onMagnify
        nsView.onPan = onPan
        nsView.onRotateChanged = onRotateChanged
        nsView.onRotateEnded = onRotateEnded
        NanightLog.info("VideoGestureSurface updateNSView view=\(nsView.debugID) \(nsView.debugGeometry)")
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        private let debugID = String(UUID().uuidString.prefix(8))

        func installGestureRecognizers(on view: VideoGestureNSView) {
            NanightLog.info("VideoGestureSurface install recognizers coordinator=\(debugID) view=\(view.debugID)")

            let magnificationRecognizer = NSMagnificationGestureRecognizer(
                target: self,
                action: #selector(handleMagnification(_:))
            )
            magnificationRecognizer.delegate = self

            let rotationRecognizer = NSRotationGestureRecognizer(
                target: self,
                action: #selector(handleRotation(_:))
            )
            rotationRecognizer.delegate = self

            view.addGestureRecognizer(magnificationRecognizer)
            view.addGestureRecognizer(rotationRecognizer)

            NanightLog.info("VideoGestureSurface recognizers installed view=\(view.debugID) count=\(view.gestureRecognizers.count)")
        }

        @objc
        private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
            guard let view = recognizer.view as? VideoGestureNSView else {
                NanightLog.warning("VideoGestureSurface magnify recognizer fired without VideoGestureNSView")
                return
            }

            NanightLog.info("VideoGestureSurface magnify view=\(view.debugID) state=\(recognizer.state.rawValue) value=\(recognizer.magnification)")
            view.onMagnify?(recognizer.magnification)
            recognizer.magnification = 0
        }

        @objc
        private func handleRotation(_ recognizer: NSRotationGestureRecognizer) {
            guard let view = recognizer.view as? VideoGestureNSView else {
                NanightLog.warning("VideoGestureSurface rotate recognizer fired without VideoGestureNSView")
                return
            }

            NanightLog.info("VideoGestureSurface rotate view=\(view.debugID) state=\(recognizer.state.rawValue) degrees=\(recognizer.rotationInDegrees)")

            switch recognizer.state {
            case .began:
                view.onRotateChanged?(0)
            case .changed:
                view.onRotateChanged?(recognizer.rotationInDegrees)
            case .ended, .cancelled, .failed:
                view.onRotateEnded?(recognizer.rotationInDegrees)
                recognizer.rotationInDegrees = 0
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            NanightLog.info("VideoGestureSurface simultaneous recognizers coordinator=\(debugID)")
            return true
        }
    }
}

private final class VideoGestureNSView: NSView {
    let debugID = String(UUID().uuidString.prefix(8))
    var onMagnify: ((CGFloat) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onRotateChanged: ((CGFloat) -> Void)?
    var onRotateEnded: ((CGFloat) -> Void)?
    private var responderRotationDegrees: CGFloat = 0
    private var responderRotationActive = false
    private var debugGestureEventMonitor: Any?
    private var lastLoggedLayoutDescription: String?

    var debugGeometry: String {
        "frame=\(frame.debugDescription) bounds=\(bounds.debugDescription) window=\(window == nil ? "nil" : "attached")"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NanightLog.info("VideoGestureNSView init view=\(debugID)")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NanightLog.info("VideoGestureNSView init coder view=\(debugID)")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    deinit {
        removeDebugGestureEventMonitor()
        NanightLog.info("VideoGestureNSView deinit view=\(debugID)")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeDebugGestureEventMonitor()

        NanightLog.info("VideoGestureNSView movedToWindow view=\(debugID) \(debugGeometry) recognizers=\(gestureRecognizers.count) responderChain=\(debugResponderChain)")

        guard window != nil else {
            return
        }

        installDebugGestureEventMonitor()
        window?.makeFirstResponder(self)
        NanightLog.info("VideoGestureNSView requested firstResponder view=\(debugID) firstResponder=\(debugFirstResponder)")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NanightLog.info("VideoGestureNSView movedToSuperview view=\(debugID) superview=\(superview.map { String(describing: type(of: $0)) } ?? "nil")")
    }

    override func layout() {
        super.layout()

        let description = debugGeometry
        guard description != lastLoggedLayoutDescription else {
            return
        }

        lastLoggedLayoutDescription = description
        NanightLog.info("VideoGestureNSView layout view=\(debugID) \(description)")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let isInside = bounds.contains(point)
        if isInside, let event = NSApp.currentEvent, event.type.isVideoGestureDebugEvent {
            NanightLog.info("VideoGestureNSView hitTest view=\(debugID) event=\(event.type.debugName) point=\(point.debugDescription) bounds=\(bounds.debugDescription)")
        }

        return isInside ? self : nil
    }

    override func beginGesture(with event: NSEvent) {
        NanightLog.info("VideoGestureNSView beginGesture view=\(debugID)")
        responderRotationDegrees = 0
        responderRotationActive = false
    }

    override func endGesture(with event: NSEvent) {
        NanightLog.info("VideoGestureNSView endGesture view=\(debugID) rotationActive=\(responderRotationActive) degrees=\(responderRotationDegrees)")
        finishResponderRotation()
    }

    override func magnify(with event: NSEvent) {
        NanightLog.info("VideoGestureNSView magnify responder view=\(debugID) value=\(event.magnification)")
        onMagnify?(event.magnification)
    }

    override func rotate(with event: NSEvent) {
        if !responderRotationActive {
            responderRotationActive = true
            responderRotationDegrees = 0
            onRotateChanged?(0)
        }

        responderRotationDegrees += CGFloat(event.rotation)
        NanightLog.info("VideoGestureNSView rotate responder view=\(debugID) delta=\(event.rotation) degrees=\(responderRotationDegrees)")
        onRotateChanged?(responderRotationDegrees)
    }

    override func scrollWheel(with event: NSEvent) {
        NanightLog.info("VideoGestureNSView scrollWheel view=\(debugID) precise=\(event.hasPreciseScrollingDeltas) deltaX=\(event.scrollingDeltaX) deltaY=\(event.scrollingDeltaY)")

        guard event.hasPreciseScrollingDeltas else {
            nextResponder?.scrollWheel(with: event)
            return
        }

        onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    private func finishResponderRotation() {
        guard responderRotationActive else {
            return
        }

        onRotateEnded?(responderRotationDegrees)
        responderRotationDegrees = 0
        responderRotationActive = false
    }

    private func installDebugGestureEventMonitor() {
        let gestureEvents: NSEvent.EventTypeMask = [.magnify, .rotate, .scrollWheel]

        debugGestureEventMonitor = NSEvent.addLocalMonitorForEvents(matching: gestureEvents) { [weak self] event in
            guard let self else {
                return event
            }

            let windowMatches = event.window === self.window
            let pointInWindow = event.locationInWindow
            let pointInView = self.convert(pointInWindow, from: nil)
            let inside = self.bounds.contains(pointInView)
            let firstResponder = self.debugFirstResponder

            NanightLog.info("VideoGestureNSView localEvent view=\(self.debugID) event=\(event.type.debugName) windowMatches=\(windowMatches) inside=\(inside) point=\(pointInView.debugDescription) firstResponder=\(firstResponder)")

            return event
        }

        NanightLog.info("VideoGestureNSView installed debug gesture event monitor view=\(debugID)")
    }

    private func removeDebugGestureEventMonitor() {
        if let debugGestureEventMonitor {
            NSEvent.removeMonitor(debugGestureEventMonitor)
            self.debugGestureEventMonitor = nil
            NanightLog.info("VideoGestureNSView removed debug gesture event monitor view=\(debugID)")
        }
    }

    private var debugFirstResponder: String {
        guard let firstResponder = window?.firstResponder else {
            return "nil"
        }

        return String(describing: type(of: firstResponder))
    }

    private var debugResponderChain: String {
        var responders: [String] = []
        var nextResponder: NSResponder? = self

        while let responder = nextResponder, responders.count < 8 {
            responders.append(String(describing: type(of: responder)))
            nextResponder = responder.nextResponder
        }

        return responders.joined(separator: " -> ")
    }
}

private extension NSEvent.EventType {
    var isVideoGestureDebugEvent: Bool {
        switch self {
        case .beginGesture, .endGesture, .magnify, .rotate, .scrollWheel:
            return true
        default:
            return false
        }
    }

    var debugName: String {
        switch self {
        case .beginGesture:
            return "beginGesture"
        case .endGesture:
            return "endGesture"
        case .magnify:
            return "magnify"
        case .rotate:
            return "rotate"
        case .scrollWheel:
            return "scrollWheel"
        default:
            return String(describing: self)
        }
    }
}

private struct LiveStatusRow: View {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)

                Text("Live")

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

            if player.lastErrorMessage != nil || player.readyStateText == "Connecting RTMPS stream" || player.readyStateText == "RTMPS playback failed" {
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
