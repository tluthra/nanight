import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class NanightAppModel: ObservableObject {
    @Published var connectionState: NanitConnectionState = .restoring
    @Published var settings: NanitUserSettings {
        didSet {
            settings.save()
            applyAudioPlaybackState()
        }
    }
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var mfaCode: String = ""
    @Published var cameras: [NanitBaby] = []
    @Published var activity = NurseryActivity()
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var streamURL: URL?
    @Published var player: AVPlayer?
    @Published var rtmpPlayer: NanightRTMPPlayer?
    @Published var climate: NanitClimateReading?
    @Published var videoPaused = false
    @Published var audioMuted = true
    @Published var lastEventRefreshAt: Date?
    @Published var lastCameraRefreshAt: Date?
    @Published var cameraStatusText: String = "Not connected"
    @Published var streamStatusText: String = "Stream unavailable"

    private static let audioMutedStorageKey = "NanightAudioMuted"

    private let api: NanitAPIClient
    private let keychain: KeychainTokenStore
    private let notifications: NanitNotificationController
    private var tokens: NanitTokens?
    private var tokenRefreshTask: Task<NanitTokens, Error>?
    private var tokenRefreshID = UUID()
    private var authGeneration = 0
    private var lastForcedStreamRefresh: Date?
    private var pendingMFAToken: String?
    private var pendingMFAEmail: String?
    private var pendingMFAPassword: String?
    private var monitorTask: Task<Void, Never>?
    private var launchNotificationBaseline = Date()
    private var lastNotifiedMotionAt: Date?
    private var lastNotifiedSoundAt: Date?
    private var wasOffline = false
    private var isVideoVisible = false

    convenience init() {
        self.init(
            api: NanitAPIClient(),
            keychain: KeychainTokenStore(),
            notifications: NanitNotificationController()
        )
    }

    init(
        api: NanitAPIClient,
        keychain: KeychainTokenStore,
        notifications: NanitNotificationController
    ) {
        self.api = api
        self.keychain = keychain
        self.notifications = notifications
        self.settings = NanitUserSettings.load()
        self.audioMuted = UserDefaults.standard.object(forKey: Self.audioMutedStorageKey) as? Bool ?? true

        NanightLog.info("App launched")

        #if DEBUG
        // Unit tests must not open the user's Keychain or connect to their camera.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            connectionState = .signedOut
            return
        }
        #endif

        Task {
            await restoreSession()
        }
    }

    var activeCamera: NanitBaby? {
        if let selectedBabyUID = settings.selectedBabyUID,
           let selected = cameras.first(where: { $0.uid == selectedBabyUID }) {
            return selected
        }

        return cameras.first
    }

    var isAuthenticated: Bool {
        if case .signedIn = connectionState {
            return true
        }
        return false
    }

    var menuBarIconState: NanightMenuBarIconState {
        switch connectionState {
        case .restoring, .offline, .authExpired:
            return .connecting
        case .signedOut, .mfaRequired:
            return .normal
        case .signedIn:
            break
        }

        let showMotion = settings.motionMenuBarStateEnabled && activity.motionActive
        let showSound = settings.soundMenuBarStateEnabled && activity.soundActive

        if showMotion && showSound {
            return .motionAndSound
        }

        if showSound {
            return .sound
        }

        if showMotion {
            return .motion
        }

        return .idle
    }

    var statusLabel: String {
        switch connectionState {
        case .signedOut:
            return "Signed out"
        case .restoring:
            return "Restoring"
        case .signedIn:
            return cameraStatusText
        case .mfaRequired:
            return "MFA required"
        case .offline(let message):
            return message
        case .authExpired:
            return "Auth expired"
        }
    }

    var isAudioMuted: Bool {
        audioMuted
    }

    private var isPlaybackAudioMuted: Bool {
        audioMuted || !isVideoVisible
    }

    private var shouldPlayStream: Bool {
        !videoPaused
    }

    func restoreSession() async {
        NanightLog.info("Restoring saved Nanit session")
        let generation = authGeneration
        do {
            guard let storedTokens = try keychain.load() else {
                NanightLog.info("No saved Nanit session found")
                connectionState = .signedOut
                return
            }

            tokens = storedTokens
            _ = try await validAccessToken(forceRefresh: true)
            guard generation == authGeneration, !Task.isCancelled else { return }
            connectionState = .signedIn
            NanightLog.info("Saved Nanit session restored")
            await refreshCameras()
            if settings.startMonitoringOnLaunch {
                startMonitoring()
            }
        } catch {
            guard generation == authGeneration, !Task.isCancelled else { return }
            NanightLog.error("Session restore failed: \(userFacing(error))")
            connectionState = .authExpired("Sign in again.")
            errorMessage = userFacing(error)
        }
    }

    func signIn() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            NanightLog.warning("Sign in blocked because email or password is empty")
            errorMessage = "Enter your Nanit email and password."
            return
        }

        NanightLog.info("Starting Nanit sign in for \(redactedEmail(trimmedEmail))")
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let newTokens = try await api.login(email: trimmedEmail, password: password)
                NanightLog.info("Nanit sign in succeeded")
                await acceptAuthenticatedSession(newTokens)
            } catch NanitAPIError.mfaRequired(let token) {
                NanightLog.warning("Nanit sign in requires MFA")
                pendingMFAToken = token
                pendingMFAEmail = trimmedEmail
                pendingMFAPassword = password
                connectionState = .mfaRequired
            } catch {
                NanightLog.error("Nanit sign in failed: \(userFacing(error))")
                connectionState = .signedOut
                errorMessage = userFacing(error)
            }

            isBusy = false
        }
    }

    func completeMFA() {
        guard let pendingMFAToken,
              let pendingMFAEmail,
              let pendingMFAPassword,
              !mfaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            NanightLog.warning("MFA verification blocked because required fields are missing")
            errorMessage = "Enter the MFA code Nanit sent you."
            return
        }

        NanightLog.info("Submitting Nanit MFA code")
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let newTokens = try await api.completeMFA(
                    email: pendingMFAEmail,
                    password: pendingMFAPassword,
                    mfaToken: pendingMFAToken,
                    mfaCode: mfaCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                NanightLog.info("Nanit MFA verification succeeded")
                await acceptAuthenticatedSession(newTokens)
            } catch {
                NanightLog.error("Nanit MFA verification failed: \(userFacing(error))")
                errorMessage = userFacing(error)
            }

            isBusy = false
        }
    }

    func refreshCameras() async {
        guard tokens != nil else {
            NanightLog.warning("Camera refresh skipped because there is no active session")
            return
        }

        NanightLog.info("Refreshing Nanit cameras")
        let generation = authGeneration
        do {
            let accessToken = try await validAccessToken()
            let updatedCameras = try await api.babies(accessToken: accessToken)
            guard generation == authGeneration, !Task.isCancelled else { return }
            cameras = updatedCameras
            lastCameraRefreshAt = Date()

            if settings.selectedBabyUID == nil || !cameras.contains(where: { $0.uid == settings.selectedBabyUID }) {
                settings.selectedBabyUID = cameras.first?.uid
            }

            if cameras.isEmpty {
                cameraStatusText = "No cameras"
                errorMessage = NanitAPIError.noCamera.localizedDescription
                NanightLog.warning("Camera refresh returned no cameras")
                prepareStream()
            } else {
                cameraStatusText = "Connected"
                NanightLog.info("Camera refresh found \(cameras.count) camera(s)")
                prepareStream()
            }

            if wasOffline {
                notifications.notify(
                    kind: .reconnected,
                    title: "Nanight reconnected",
                    body: activeCamera?.name ?? "Nanit camera is reachable again.",
                    cooldown: settings.notificationCooldownSeconds,
                    notificationsEnabled: settings.notificationsEnabled && settings.notifyOnOffline
                )
            }
            wasOffline = false
            connectionState = .signedIn
        } catch {
            guard generation == authGeneration, !Task.isCancelled else { return }
            NanightLog.error("Camera refresh failed: \(userFacing(error))")
            markOffline(error)
        }
    }

    func selectCamera(_ babyUID: String) {
        NanightLog.info("Selecting camera \(babyUID)")
        settings.selectedBabyUID = babyUID
        activity = NurseryActivity()
        climate = nil
        prepareStream()
        startMonitoring()
    }

    func reconnectStream() {
        NanightLog.info("Reconnecting stream")
        if let rtmpPlayer {
            rtmpPlayer.reconnect()
        } else {
            prepareStream()
            if shouldPlayStream { player?.play() }
        }
    }

    func toggleVideo() {
        videoPaused.toggle()
        NanightLog.info(videoPaused ? "Video paused" : "Video resumed")
        if videoPaused {
            player?.pause()
            rtmpPlayer?.pause()
        } else {
            player?.play()
            rtmpPlayer?.play()
        }
    }

    func toggleAudio() {
        audioMuted.toggle()
        UserDefaults.standard.set(audioMuted, forKey: Self.audioMutedStorageKey)
        NanightLog.info(isAudioMuted ? "Audio muted" : "Audio unmuted")
        applyAudioPlaybackState()
    }

    func setVideoVisible(_ visible: Bool) {
        guard isVideoVisible != visible else {
            return
        }

        isVideoVisible = visible
        // Visibility controls sound, not the connection. Keep receiving current
        // frames so reopening the retained popover does not need another handshake.
        NanightLog.info(visible ? "Video popover opened; reusing stream" : "Video popover closed; muting audio")
        applyAudioPlaybackState()
    }

    private func applyAudioPlaybackState() {
        let muted = isPlaybackAudioMuted
        player?.isMuted = muted
        rtmpPlayer?.updateMuted(muted)
    }

    func requestNotificationPermission() {
        NanightLog.info("Requesting notification permission")
        Task {
            let granted = await notifications.requestPermission()
            NanightLog.info("Notification permission \(granted ? "granted" : "denied")")
            settings.notificationsEnabled = granted
            if !granted {
                errorMessage = "macOS notification permission was not granted."
            }
        }
    }

    func startMonitoring() {
        monitorTask?.cancel()

        guard isAuthenticated else {
            NanightLog.warning("Monitoring start skipped because app is not signed in")
            return
        }

        NanightLog.info("Starting activity polling")

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEvents()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopMonitoring() {
        NanightLog.info("Stopping activity polling")
        monitorTask?.cancel()
        monitorTask = nil
    }

    func refreshEvents() async {
        guard let camera = activeCamera else {
            NanightLog.warning("Event refresh skipped because no camera is selected")
            return
        }

        let generation = authGeneration
        do {
            let accessToken = try await validAccessToken()
            let events = try await api.messages(accessToken: accessToken, babyUID: camera.uid, limit: 20)
            await refreshClimate(accessToken: accessToken, camera: camera)
            guard generation == authGeneration, !Task.isCancelled, activeCamera?.uid == camera.uid else { return }
            let newActivity = NurseryActivity.current(
                from: events,
                activeWindow: settings.eventActiveWindowSeconds
            )
            handleActivityNotifications(newActivity, camera: camera)
            activity = newActivity
            lastEventRefreshAt = Date()
            cameraStatusText = "Live"
            connectionState = .signedIn
            wasOffline = false
            NanightLog.info("Event refresh succeeded for \(camera.name): motion=\(newActivity.motionActive), sound=\(newActivity.soundActive)")
        } catch {
            guard generation == authGeneration, !Task.isCancelled, activeCamera?.uid == camera.uid else { return }
            NanightLog.error("Event refresh failed: \(userFacing(error))")
            markOffline(error)
        }
    }

    func signOut() {
        NanightLog.info("Signing out")
        authGeneration += 1
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        lastForcedStreamRefresh = nil
        monitorTask?.cancel()
        monitorTask = nil
        player?.pause()
        player = nil
        rtmpPlayer?.close()
        rtmpPlayer = nil
        streamURL = nil
        streamStatusText = "Signed out"
        tokens = nil
        cameras = []
        activity = NurseryActivity()
        climate = nil
        pendingMFAToken = nil
        pendingMFAEmail = nil
        pendingMFAPassword = nil
        password = ""
        mfaCode = ""
        cameraStatusText = "Signed out"

        do {
            try keychain.delete()
        } catch {
            NanightLog.error("Keychain sign out cleanup failed: \(userFacing(error))")
            errorMessage = userFacing(error)
        }

        connectionState = .signedOut
    }

    func copyDiagnosticsToPasteboard() {
        let camera = activeCamera
        let lines = [
            "Nanight diagnostics",
            "Account state: \(statusLabel)",
            "Camera: \(camera?.name ?? "none")",
            "Baby UID: \(camera?.uid ?? "none")",
            "Camera UID: \(camera?.cameraUID ?? "none")",
            "Speaker UID: \(camera?.speakerUID ?? "none")",
            "Stream URL present: \(streamURL == nil ? "no" : "yes")",
            "Stream status: \(rtmpPlayer?.readyStateText ?? streamStatusText)",
            "Video frames: \(rtmpPlayer.map { String(describing: $0.videoFrameState) } ?? "unavailable")",
            "Motion active: \(activity.motionActive)",
            "Sound active: \(activity.soundActive)",
            "Temperature: \(climate?.temperatureCelsius.map { "\($0) C" } ?? "unknown")",
            "Humidity: \(climate?.humidityPercent.map { "\($0)%" } ?? "unknown")",
            "Last camera refresh: \(lastCameraRefreshAt?.description ?? "never")",
            "Last event refresh: \(lastEventRefreshAt?.description ?? "never")",
            "",
            "Protocol references:",
            NanitAPIClient.protocolReferences.map { "- \($0.title): \($0.url.absoluteString)" }.joined(separator: "\n")
        ].joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines, forType: .string)
        NanightLog.info("Copied diagnostics snapshot to pasteboard")
    }

    private func acceptAuthenticatedSession(_ newTokens: NanitTokens) async {
        do {
            NanightLog.info("Saving authenticated Nanit session")
            try keychain.save(newTokens)
            authGeneration += 1
            tokenRefreshTask?.cancel()
            tokenRefreshTask = nil
            tokens = newTokens
            pendingMFAToken = nil
            pendingMFAEmail = nil
            pendingMFAPassword = nil
            password = ""
            mfaCode = ""
            connectionState = .signedIn
            await refreshCameras()
            startMonitoring()
        } catch {
            NanightLog.error("Saving authenticated session failed: \(userFacing(error))")
            errorMessage = userFacing(error)
        }
    }

    private func validAccessToken(forceRefresh: Bool = false, updatePlayback: Bool = true) async throws -> String {
        guard let currentTokens = tokens else {
            throw NanitAPIError.authExpired("Not signed in.")
        }
        guard forceRefresh || currentTokens.shouldRefresh || tokenRefreshTask != nil else {
            return currentTokens.accessToken
        }
        let generation = authGeneration
        if tokenRefreshTask == nil {
            tokenRefreshID = UUID()
            tokenRefreshTask = Task { [api] in
                try await api.refresh(accessToken: currentTokens.accessToken, refreshToken: currentTokens.refreshToken)
            }
        }
        guard let refresh = tokenRefreshTask else { throw CancellationError() }
        let refreshID = tokenRefreshID
        do {
            let refreshed = try await refresh.value
            guard generation == authGeneration, tokens != nil else { throw CancellationError() }
            // Concurrent callers share the request; only the first persists and updates playback.
            if tokenRefreshTask != nil, tokenRefreshID == refreshID {
                try keychain.save(refreshed)
                tokens = refreshed
                tokenRefreshTask = nil
                NanightLog.info("Nanit access token refreshed")
                if updatePlayback { prepareStream() }
            }
            return refreshed.accessToken
        } catch {
            if generation == authGeneration, tokenRefreshID == refreshID {
                tokenRefreshTask = nil
                if let apiError = error as? NanitAPIError {
                    switch apiError {
                    case .authExpired, .invalidCredentials:
                        connectionState = .authExpired("Sign in again.")
                        stopMonitoring()
                        rtmpPlayer?.close()
                    default: break
                    }
                }
            }
            throw error
        }
    }

    private func playbackURL(for babyUID: String, forceRefresh: Bool) async throws -> URL {
        let generation = authGeneration
        let mayForce = forceRefresh && (lastForcedStreamRefresh.map { Date().timeIntervalSince($0) >= 60 } ?? true)
        if mayForce { lastForcedStreamRefresh = Date() }
        let accessToken = try await validAccessToken(forceRefresh: mayForce, updatePlayback: false)
        guard !Task.isCancelled, generation == authGeneration, activeCamera?.uid == babyUID,
              let url = api.rtmpsStreamURL(babyUID: babyUID, accessToken: accessToken)
        else { throw CancellationError() }
        streamURL = url
        return url
    }

    private func prepareStream() {
        guard let camera = activeCamera,
              let accessToken = tokens?.accessToken,
              let url = api.rtmpsStreamURL(babyUID: camera.uid, accessToken: accessToken)
        else {
            NanightLog.warning("Stream setup skipped because camera or session is missing")
            streamURL = nil
            player?.pause()
            player = nil
            rtmpPlayer?.close()
            rtmpPlayer = nil
            streamStatusText = "Stream unavailable"
            return
        }

        NanightLog.info("Preparing stream for \(camera.name)")
        streamURL = url

        guard url.scheme == "http" || url.scheme == "https" else {
            player?.pause()
            player = nil
            let playback = rtmpPlayer ?? NanightRTMPPlayer()
            rtmpPlayer = playback
            playback.resolveStreamURL = { [weak self] forceRefresh in
                guard let self else { throw CancellationError() }
                return try await self.playbackURL(for: camera.uid, forceRefresh: forceRefresh)
            }
            playback.start(url: url, muted: isPlaybackAudioMuted, paused: !shouldPlayStream)
            streamStatusText = playback.readyStateText
            NanightLog.info("Prepared HaishinKit playback for \(url.scheme ?? "unknown") stream")
            return
        }

        rtmpPlayer?.close()
        rtmpPlayer = nil
        streamStatusText = "Connecting stream"
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isPlaybackAudioMuted
        player = newPlayer

        if shouldPlayStream {
            newPlayer.play()
            streamStatusText = "Stream playback started"
            NanightLog.info("Stream playback started")
        } else {
            streamStatusText = "Stream prepared while paused"
            NanightLog.info("Stream prepared while video is paused")
        }
    }

    private func refreshClimate(accessToken: String, camera: NanitBaby) async {
        let generation = authGeneration
        do {
            guard let reading = try await api.climate(accessToken: accessToken, cameraUID: camera.cameraUID) else {
                NanightLog.info("Climate refresh returned no sensor values for \(camera.name)")
                return
            }

            guard generation == authGeneration, !Task.isCancelled, activeCamera?.uid == camera.uid else { return }
            climate = reading
            NanightLog.info(
                "Climate refresh succeeded for \(camera.name): tempC=\(reading.temperatureCelsius?.description ?? "nil"), humidity=\(reading.humidityPercent?.description ?? "nil")"
            )
        } catch {
            NanightLog.warning("Climate refresh failed: \(userFacing(error))")
        }
    }

    private func handleActivityNotifications(_ newActivity: NurseryActivity, camera: NanitBaby) {
        if let motionAt = newActivity.lastMotionAt,
           motionAt > launchNotificationBaseline,
           motionAt != lastNotifiedMotionAt,
           settings.notifyOnMotion {
            lastNotifiedMotionAt = motionAt
            notifications.notify(
                kind: .motion,
                title: "Motion detected",
                body: camera.name,
                cooldown: settings.notificationCooldownSeconds,
                notificationsEnabled: settings.notificationsEnabled
            )
        }

        if let soundAt = newActivity.lastSoundAt,
           soundAt > launchNotificationBaseline,
           soundAt != lastNotifiedSoundAt,
           settings.notifyOnSound {
            lastNotifiedSoundAt = soundAt
            notifications.notify(
                kind: .sound,
                title: "Sound detected",
                body: camera.name,
                cooldown: settings.notificationCooldownSeconds,
                notificationsEnabled: settings.notificationsEnabled
            )
        }
    }

    private func markOffline(_ error: Error) {
        if case .authExpired = connectionState { return }
        let message = userFacing(error)
        cameraStatusText = "Reconnecting"
        connectionState = .offline(message)

        if !wasOffline {
            NanightLog.warning("Marking app offline: \(message)")
            notifications.notify(
                kind: .offline,
                title: "Nanight connection issue",
                body: message,
                cooldown: settings.notificationCooldownSeconds,
                notificationsEnabled: settings.notificationsEnabled && settings.notifyOnOffline
            )
        }

        wasOffline = true
    }

    private func userFacing(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private func redactedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "redacted email"
        }

        let name = parts[0]
        let prefix = name.prefix(2)
        return "\(prefix)***@\(parts[1])"
    }
}
