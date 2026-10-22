import Combine
import Foundation
import Network

/// Basic installation counts only. Never receives camera or account data.
@MainActor
final class NanightAnalytics: ObservableObject {
    static let shared = NanightAnalytics(
        endpoint: (Bundle.main.object(forInfoDictionaryKey: "NanightAnalyticsURL") as? String)
            .flatMap(URL.init(string:)),
        networkEnabled: productionBuild
    )

    private static var productionBuild: Bool {
        #if DEBUG
        return false
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && NSClassFromString("XCTestCase") == nil
        #endif
    }

    static let enabledKey = "NanightAnalyticsEnabled"
    static let installationKey = "NanightAnalyticsInstallationID"
    static let lastAttemptKey = "NanightAnalyticsLastAttempt"
    static let lastSuccessKey = "NanightAnalyticsLastSuccess"
    static let retryInterval: TimeInterval = 15 * 60

    @Published private(set) var sharingEnabled: Bool
    private let defaults: UserDefaults
    private let endpoint: URL?
    private let networkEnabled: Bool
    private let appVersion: String
    private let macOSVersion: String
    private let send: (URLRequest) async throws -> Bool
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var requestTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        endpoint: URL?,
        networkEnabled: Bool,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        macOSVersion: String = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
        send: @escaping (URLRequest) async throws -> Bool = { try await NanightAnalytics.sendRequest($0) }
    ) {
        self.defaults = defaults
        self.endpoint = endpoint
        self.networkEnabled = networkEnabled
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.send = send
        sharingEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard timer == nil, networkEnabled, sharingEnabled, endpoint?.scheme == "https" else { return }
        checkIn()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIn() }
        }
        timer.tolerance = 30
        self.timer = timer
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.checkIn() }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "NanightAnalyticsConnectivity", qos: .utility))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        requestTask?.cancel()
        requestTask = nil
    }

    func setSharingEnabled(_ enabled: Bool) {
        sharingEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func checkIn(at now: Date = Date()) {
        guard sharingEnabled, networkEnabled, requestTask == nil,
              let endpoint, endpoint.scheme == "https" else { return }
        if let lastSuccess = defaults.object(forKey: Self.lastSuccessKey) as? Date,
           floor(lastSuccess.timeIntervalSince1970 / 86_400) == floor(now.timeIntervalSince1970 / 86_400) { return }
        if let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date,
           (0..<Self.retryInterval).contains(now.timeIntervalSince(lastAttempt)) { return }

        let installationID: String
        if let saved = defaults.string(forKey: Self.installationKey), UUID(uuidString: saved) != nil {
            installationID = saved
        } else {
            installationID = UUID().uuidString.lowercased()
            defaults.set(installationID, forKey: Self.installationKey)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nanight", forHTTPHeaderField: "User-Agent")
        guard let body = try? JSONEncoder().encode(Payload(
            installation_id: installationID,
            app_version: appVersion,
            macos_version: macOSVersion
        )) else { return }
        request.httpBody = body

        // Persist before sending so relaunches and network changes respect the
        // retry cooldown. Only an acknowledged request completes the UTC day.
        defaults.set(now, forKey: Self.lastAttemptKey)
        requestTask = Task { [weak self, send] in
            // No UI error state, logging, notification, or immediate retry. Analytics
            // must never affect monitoring, account state, or the settings toggle.
            guard !Task.isCancelled else { return }
            let succeeded = (try? await send(request)) == true
            guard !Task.isCancelled else { return }
            if succeeded {
                // Use the attempt's day, so a response crossing midnight cannot
                // suppress the new day's check-in. The server deduplicates dates.
                self?.defaults.set(now, forKey: Self.lastSuccessKey)
                self?.defaults.removeObject(forKey: Self.lastAttemptKey)
            }
            self?.requestTask = nil
        }
    }

    private struct Payload: Encodable {
        let installation_id: String
        let app_version: String
        let macos_version: String
    }

    nonisolated static func sendRequest(
        _ request: URLRequest,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Bool {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: NanightAnalyticsSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Only 2xx acknowledges delivery. All other outcomes retry quietly later.
        // Stop at the headers so even a huge or endless error body cannot consume
        // unbounded memory or keep the connection open.
        let (_, response) = try await session.bytes(for: request)
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }
}

final class NanightAnalyticsSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Keep normal TLS certificate validation, but never use credentials or
        // attempt interactive authentication for an analytics endpoint.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
