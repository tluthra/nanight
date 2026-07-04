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
            player?.isMuted = isAudioMuted
            rtmpPlayer?.updateMuted(isAudioMuted)
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
    @Published var videoPaused = false
    @Published var audioMuted = true
    @Published var lastEventRefreshAt: Date?
    @Published var lastCameraRefreshAt: Date?
    @Published var cameraStatusText: String = "Not connected"
    @Published var streamStatusText: String = "Stream unavailable"

    private let api: NanitAPIClient
    private let keychain: KeychainTokenStore
    private let notifications: NanitNotificationController
    private var tokens: NanitTokens?
    private var pendingMFAToken: String?
    private var pendingMFAEmail: String?
    private var pendingMFAPassword: String?
    private var monitorTask: Task<Void, Never>?
    private var launchNotificationBaseline = Date()
    private var lastNotifiedMotionAt: Date?
    private var lastNotifiedSoundAt: Date?
    private var wasOffline = false

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
        self.audioMuted = settings.startMuted

        NanightLog.info("App launched")

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

    var menuBarSystemImage: String {
        switch connectionState {
        case .authExpired:
            return "person.crop.circle.badge.exclamationmark"
        case .offline:
            return "wifi.slash"
        case .restoring:
            return "arrow.triangle.2.circlepath"
        case .signedOut, .mfaRequired:
            return "moon"
        case .signedIn:
            break
        }

        let showMotion = settings.motionMenuBarStateEnabled && activity.motionActive
        let showSound = settings.soundMenuBarStateEnabled && activity.soundActive

        if showMotion && showSound {
            return "bell.badge.fill"
        }

        if showSound {
            return "waveform"
        }

        if showMotion {
            return "figure.walk.motion"
        }

        return "video.fill"
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
        audioMuted || settings.startMuted
    }

    func restoreSession() async {
        NanightLog.info("Restoring saved Nanit session")

        do {
            guard let storedTokens = try keychain.load() else {
                NanightLog.info("No saved Nanit session found")
                connectionState = .signedOut
                return
            }

            tokens = storedTokens
            _ = try await validAccessToken(forceRefresh: true)
            connectionState = .signedIn
            NanightLog.info("Saved Nanit session restored")
            await refreshCameras()
            if settings.startMonitoringOnLaunch {
                startMonitoring()
            }
        } catch {
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

        do {
            let accessToken = try await validAccessToken()
            cameras = try await api.babies(accessToken: accessToken)
            lastCameraRefreshAt = Date()

            if settings.selectedBabyUID == nil || !cameras.contains(where: { $0.uid == settings.selectedBabyUID }) {
                settings.selectedBabyUID = cameras.first?.uid
            }

            if cameras.isEmpty {
                cameraStatusText = "No cameras"
                errorMessage = NanitAPIError.noCamera.localizedDescription
                NanightLog.warning("Camera refresh returned no cameras")
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
            NanightLog.error("Camera refresh failed: \(userFacing(error))")
            markOffline(error)
        }
    }

    func selectCamera(_ babyUID: String) {
        NanightLog.info("Selecting camera \(babyUID)")
        settings.selectedBabyUID = babyUID
        activity = NurseryActivity()
        prepareStream()
        startMonitoring()
    }

    func reconnectStream() {
        NanightLog.info("Reconnecting stream")
        prepareStream()
        if !videoPaused {
            player?.play()
            rtmpPlayer?.play()
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
        NanightLog.info(isAudioMuted ? "Audio muted" : "Audio unmuted")
        settings.startMuted = audioMuted
        player?.isMuted = isAudioMuted
        rtmpPlayer?.updateMuted(isAudioMuted)
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

        do {
            let accessToken = try await validAccessToken()
            let events = try await api.messages(accessToken: accessToken, babyUID: camera.uid, limit: 20)
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
            NanightLog.error("Event refresh failed: \(userFacing(error))")
            markOffline(error)
        }
    }

    func signOut() {
        NanightLog.info("Signing out")
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
            "Stream status: \(streamStatusText)",
            "Motion active: \(activity.motionActive)",
            "Sound active: \(activity.soundActive)",
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

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard var currentTokens = tokens else {
            NanightLog.error("Access token requested without an active session")
            throw NanitAPIError.authExpired("Not signed in.")
        }

        let previousAccessToken = currentTokens.accessToken

        if forceRefresh || currentTokens.shouldRefresh {
            NanightLog.info("Refreshing Nanit access token")

            do {
                currentTokens = try await api.refresh(
                    accessToken: currentTokens.accessToken,
                    refreshToken: currentTokens.refreshToken
                )
            } catch {
                NanightLog.error("Access token refresh failed: \(userFacing(error))")
                throw error
            }

            try keychain.save(currentTokens)
            tokens = currentTokens
            NanightLog.info("Nanit access token refreshed")

            if currentTokens.accessToken != previousAccessToken {
                prepareStream()
            }
        }

        return currentTokens.accessToken
    }

    private func prepareStream() {
        guard let camera = activeCamera,
              let accessToken = tokens?.accessToken,
              let url = api.rtmpsStreamURL(babyUID: camera.uid, accessToken: accessToken)
        else {
            NanightLog.warning("Stream setup skipped because camera or session is missing")
            streamURL = nil
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
            playback.start(url: url, muted: isAudioMuted, paused: videoPaused)
            streamStatusText = playback.readyStateText
            NanightLog.info("Prepared HaishinKit playback for \(url.scheme ?? "unknown") stream")
            return
        }

        rtmpPlayer?.close()
        rtmpPlayer = nil
        streamStatusText = "Connecting stream"
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isAudioMuted
        player = newPlayer

        if !videoPaused {
            newPlayer.play()
            streamStatusText = "Stream playback started"
            NanightLog.info("Stream playback started")
        } else {
            streamStatusText = "Stream prepared while paused"
            NanightLog.info("Stream prepared while video is paused")
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
