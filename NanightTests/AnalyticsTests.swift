import Combine
import Foundation
import Testing
@testable import Nanight

@MainActor
struct AnalyticsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "NanightAnalyticsTests.\(UUID().uuidString)")!
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func sharesOnlyTheAgreedFieldsAndDefaultsOn() async throws {
        let storage = defaults()
        var requests: [URLRequest] = []
        let analytics = NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
            networkEnabled: true, appVersion: "0.0.9", macOSVersion: "26", send: { requests.append($0); return true })
        #expect(analytics.sharingEnabled)
        analytics.checkIn()
        await settle()
        let request = try #require(requests.first)
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(Set(payload.keys) == ["installation_id", "app_version", "macos_version"])
        let installationID = try #require(payload["installation_id"])
        #expect(UUID(uuidString: installationID) != nil)
        #expect(payload["app_version"] == "0.0.9")
        #expect(payload["macos_version"] == "26")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Nanight")
    }

    @Test func successfulUTCDayAndIDSurviveRelaunch() async throws {
        let storage = defaults()
        let now = ISO8601DateFormatter().date(from: "2026-10-21T23:55:00Z")!
        var requests: [URLRequest] = []
        func makeAnalytics() -> NanightAnalytics {
            NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
                networkEnabled: true, send: { requests.append($0); return true })
        }
        let first = makeAnalytics()
        first.checkIn(at: now)
        first.checkIn(at: now)
        await settle()
        let savedID = storage.string(forKey: NanightAnalytics.installationKey)
        let relaunched = makeAnalytics()
        relaunched.checkIn(at: now.addingTimeInterval(-3_600))
        relaunched.checkIn(at: now.addingTimeInterval(299))
        await settle()
        #expect(requests.count == 1)
        // The next UTC date is eligible even though only five minutes elapsed.
        relaunched.checkIn(at: now.addingTimeInterval(300))
        await settle()
        #expect(requests.count == 2)
        #expect(storage.string(forKey: NanightAnalytics.installationKey) == savedID)
    }

    @Test func optOutPersistsAndPreventsIDCreationOrRequests() async {
        let storage = defaults()
        var count = 0
        let analytics = NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
            networkEnabled: true, send: { _ in count += 1; return true })
        analytics.setSharingEnabled(false)
        analytics.start()
        analytics.checkIn()
        let relaunched = NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
            networkEnabled: true, send: { _ in count += 1; return true })
        relaunched.checkIn()
        await settle()
        #expect(!relaunched.sharingEnabled)
        #expect(count == 0)
        #expect(storage.string(forKey: NanightAnalytics.installationKey) == nil)
        #expect(storage.object(forKey: NanightAnalytics.lastAttemptKey) == nil)
    }

    @Test func optOutCancelsPendingRequestAndReenablingDoesNotSendAgain() async {
        let storage = defaults()
        var sent = 0
        var cancelled = false
        let analytics = NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
            networkEnabled: true, send: { _ in
                sent += 1
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = Task.isCancelled }
                return true
            })
        analytics.checkIn()
        await settle()
        analytics.setSharingEnabled(false)
        await settle()
        #expect(cancelled)
        #expect(storage.object(forKey: NanightAnalytics.lastSuccessKey) == nil)
        analytics.setSharingEnabled(true)
        await settle()
        #expect(sent == 1)
        analytics.stop()
    }

    @Test func failuresRetryAfterCooldownAndSuccessCompletesTheDay() async {
        let storage = defaults()
        let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
        var attempts = 0
        func makeAnalytics() -> NanightAnalytics {
            NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
                networkEnabled: true, send: { _ in
                    attempts += 1
                    if attempts == 1 { throw URLError(.notConnectedToInternet) }
                    return true
                })
        }
        let analytics = makeAnalytics()
        analytics.checkIn(at: now)
        await settle()
        #expect(storage.object(forKey: NanightAnalytics.lastSuccessKey) == nil)
        let relaunched = makeAnalytics()
        relaunched.checkIn(at: now.addingTimeInterval(899))
        await settle()
        #expect(attempts == 1)
        relaunched.checkIn(at: now.addingTimeInterval(900))
        await settle()
        #expect(attempts == 2)
        #expect(storage.object(forKey: NanightAnalytics.lastSuccessKey) as? Date == now.addingTimeInterval(900))
        relaunched.checkIn(at: now.addingTimeInterval(3_600))
        await settle()
        #expect(attempts == 2)
    }

    @Test func wakingOrRelaunchingAfterMissedDaysRecordsOnlyCurrentActivity() async {
        let storage = defaults()
        let now = Date()
        storage.set(now.addingTimeInterval(-3 * 86_400), forKey: NanightAnalytics.lastSuccessKey)
        var attempts = 0
        let analytics = NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
            networkEnabled: true, send: { _ in attempts += 1; return true })
        analytics.start()
        await settle()
        #expect(attempts == 1)
        #expect((storage.object(forKey: NanightAnalytics.lastSuccessKey) as? Date)?.timeIntervalSince(now) ?? -1 >= 0)
        analytics.checkIn()
        await settle()
        #expect(attempts == 1)
        analytics.stop()
    }

    @Test func clockCorrectionDoesNotSuppressRetriesForDays() async {
        let storage = defaults()
        let now = Date()
        storage.set(now.addingTimeInterval(2 * 86_400), forKey: NanightAnalytics.lastAttemptKey)
        var attempts = 0
        let analytics = NanightAnalytics(defaults: storage, endpoint: URL(string: "https://example.com/v1/ping"),
            networkEnabled: true, send: { _ in attempts += 1; return true })
        analytics.checkIn(at: now)
        await settle()
        #expect(attempts == 1)
    }

    @Test func developmentAndUnconfiguredBuildsNeverSend() async {
        for (endpoint, enabled) in [("https://example.com/v1/ping", false), ("", true), ("http://example.com/v1/ping", true)] {
            let storage = defaults()
            var sent = false
            let analytics = NanightAnalytics(defaults: storage, endpoint: URL(string: endpoint),
                networkEnabled: enabled, send: { _ in sent = true; return true })
            analytics.start()
            analytics.checkIn()
            await settle()
            #expect(!sent)
            #expect(storage.string(forKey: NanightAnalytics.installationKey) == nil)
            analytics.stop()
        }
    }

    @Test(arguments: ["200", "204", "401", "403", "429", "500", "503", "offline", "timeout", "dns", "tls"])
    func transportFailuresAndEndlessResponsesStaySilent(scenario: String) async throws {
        let storage = defaults()
        let now = Date()
        var attempts = 0
        var finished = 0
        var publishedChanges = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsFailureProtocol.self]
        let analytics = NanightAnalytics(defaults: storage,
            endpoint: URL(string: "https://analytics.test/\(scenario)"), networkEnabled: true, send: { request in
                attempts += 1
                defer { finished += 1 }
                return try await NanightAnalytics.sendRequest(request, configuration: configuration)
            })
        let observation = analytics.objectWillChange.sink { publishedChanges += 1 }
        defer { observation.cancel(); analytics.stop() }

        analytics.checkIn(at: now)
        // These responses intentionally never finish their bodies. Waiting for
        // the body instead of stopping at headers would fail this bounded test.
        for _ in 0..<200 where finished == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished == 1)
        await settle()
        analytics.checkIn(at: now.addingTimeInterval(60))
        await settle()
        #expect(attempts == 1)
        #expect(analytics.sharingEnabled)
        #expect(publishedChanges == 0)
        let succeeded = ["200", "204"].contains(scenario)
        #expect((storage.object(forKey: NanightAnalytics.lastSuccessKey) != nil) == succeeded)

        analytics.checkIn(at: now.addingTimeInterval(succeeded ? 86_400 : 900))
        for _ in 0..<200 where finished < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished == 2)
        #expect(publishedChanges == 0)
    }

    @Test func transportRefusesRedirectsAndCredentialChallenges() {
        let delegate = NanightAnalyticsSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://analytics.test/")!
        let task = session.dataTask(with: url)
        let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var redirectDecisionReceived = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://other.test/")!)) { request in
                redirectDecisionReceived = true
                #expect(request == nil)
            }
        #expect(redirectDecisionReceived)

        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust] {
            let space = URLProtectionSpace(host: "analytics.test", port: 443, protocol: "https",
                realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: AnalyticsChallengeSender())
            var challengeDecisionReceived = false
            delegate.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                challengeDecisionReceived = true
                #expect(disposition == (method == NSURLAuthenticationMethodServerTrust
                    ? .performDefaultHandling : .cancelAuthenticationChallenge))
                #expect(credential == nil)
            }
            #expect(challengeDecisionReceived)
        }
    }
}

private final class AnalyticsFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "analytics.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.url!.lastPathComponent
        let errors: [String: URLError.Code] = ["offline": .notConnectedToInternet, "timeout": .timedOut,
            "dns": .cannotFindHost, "tls": .serverCertificateUntrusted]
        if let code = errors[scenario] {
            client?.urlProtocol(self, didFailWithError: URLError(code))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: Int(scenario)!, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Deliberately no didFinishLoading, like an endlessly streaming body.
        }
    }
    override func stopLoading() {}
}

private final class AnalyticsChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
