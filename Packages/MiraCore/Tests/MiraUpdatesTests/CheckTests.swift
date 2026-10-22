import Foundation
import Testing
@testable import MiraUpdates

extension StubbedNetwork {
@Suite("Check flow, throttle and skip")
struct CheckTests {
    let current = SemanticVersion("0.2.0")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func checker() -> UpdateChecker {
        UpdateChecker(session: StubProtocol.session, userAgent: "Mira-Updater/test")
    }

    private func serve(tag: String, status: Int = 200) {
        let body = #"{"tag_name":"\#(tag)","name":"Mira","body":"Notes","html_url":"https://github.com/dwjames88/mira/releases/tag/\#(tag)","assets":[]}"#
        StubProtocol.install { _ in .data(Data(body.utf8), status: status) }
    }

    @Test func sendsGitHubHeaders() async {
        serve(tag: "v0.2.0")
        _ = await checker().check(current: current, trigger: .manual, preferences: UpdatePreferences(defaults: scratchDefaults()), now: now)
        let request = StubProtocol.requests.last
        #expect(request?.url == UpdateChecker.latestReleaseURL)
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == "Mira-Updater/test")
    }

    @Test func sameVersionIsUpToDate() async {
        serve(tag: "v0.2.0")
        let report = await checker().check(current: current, trigger: .manual, preferences: UpdatePreferences(defaults: scratchDefaults()), now: now)
        #expect(report == .upToDate(current: current, latest: SemanticVersion("0.2.0")!))
    }

    @Test func newerVersionIsAvailableAndOlderIsNot() async {
        let prefs = UpdatePreferences(defaults: scratchDefaults())
        serve(tag: "v0.10.0")
        if case .available(let release) = await checker().check(current: current, trigger: .manual, preferences: prefs, now: now) {
            #expect(release.version == SemanticVersion("0.10.0"))
        } else { Issue.record("expected .available") }
        serve(tag: "v0.1.9")
        let older = await checker().check(current: current, trigger: .manual, preferences: prefs, now: now)
        #expect(older == .upToDate(current: current, latest: SemanticVersion("0.1.9")!))
    }

    @Test func automaticChecksAreThrottledToOncePerDay() async {
        let prefs = UpdatePreferences(defaults: scratchDefaults())
        serve(tag: "v0.3.0")
        let first = await checker().check(current: current, trigger: .launch, preferences: prefs, now: now)
        guard case .available = first else { Issue.record("first launch check should run"); return }
        #expect(prefs.lastCheck == now)
        let count = StubProtocol.requests.count
        #expect(await checker().check(current: current, trigger: .launch, preferences: prefs, now: now.addingTimeInterval(3_600)) == .notDue)
        #expect(await checker().check(current: current, trigger: .launch, preferences: prefs, now: now.addingTimeInterval(86_399)) == .notDue)
        #expect(StubProtocol.requests.count == count)   // nothing hit the network
        guard case .available = await checker().check(current: current, trigger: .launch, preferences: prefs, now: now.addingTimeInterval(86_400)) else {
            Issue.record("a day later the check should run again"); return
        }
        #expect(StubProtocol.requests.count == count + 1)
    }

    @Test func manualCheckIgnoresThrottleAndSwitch() async {
        let prefs = UpdatePreferences(defaults: scratchDefaults())
        prefs.automaticChecksEnabled = false
        prefs.lastCheck = now
        serve(tag: "v0.3.0")
        #expect(await checker().check(current: current, trigger: .launch, preferences: prefs, now: now.addingTimeInterval(10)) == .notDue)
        guard case .available = await checker().check(current: current, trigger: .manual, preferences: prefs, now: now.addingTimeInterval(10)) else {
            Issue.record("manual should always check"); return
        }
    }

    @Test func switchDefaultsOn() {
        #expect(UpdatePreferences(defaults: scratchDefaults()).automaticChecksEnabled)
    }

    @Test func skippedVersionIsHiddenOnLaunchButShownManually() async {
        let prefs = UpdatePreferences(defaults: scratchDefaults())
        prefs.skippedVersion = SemanticVersion("0.3.0")
        serve(tag: "v0.3.0")
        guard case .skipped = await checker().check(current: current, trigger: .launch, preferences: prefs, now: now) else {
            Issue.record("launch should report skipped"); return
        }
        guard case .available = await checker().check(current: current, trigger: .manual, preferences: prefs, now: now) else {
            Issue.record("manual should still offer a skipped version"); return
        }
        // A newer release than the skipped one is offered again.
        serve(tag: "v0.3.1")
        guard case .available = await checker().check(current: current, trigger: .launch, preferences: prefs, now: now.addingTimeInterval(200_000)) else {
            Issue.record("0.3.1 should not be skipped"); return
        }
    }

    @Test func skippedVersionPersists() {
        let defaults = scratchDefaults()
        UpdatePreferences(defaults: defaults).skippedVersion = SemanticVersion("v1.4.0")
        #expect(UpdatePreferences(defaults: defaults).skippedVersion == SemanticVersion("1.4.0"))
        UpdatePreferences(defaults: defaults).skippedVersion = nil
        #expect(UpdatePreferences(defaults: defaults).skippedVersion == nil)
    }

    // MARK: Failures

    @Test(arguments: [404, 401, 403, 500])
    func automaticHttpErrorsFailSilently(status: Int) async {
        serve(tag: "v0.3.0", status: status)
        let prefs = UpdatePreferences(defaults: scratchDefaults())
        let report = await checker().check(current: current, trigger: .launch, preferences: prefs, now: now)
        #expect(report == .silentFailure(.httpStatus(status)))
        #expect(prefs.lastCheck == nil)   // a failure does not use up the day's check
    }

    @Test func automaticOfflineFailsSilently() async {
        StubProtocol.install { _ in .failure(URLError(.notConnectedToInternet)) }
        let report = await checker().check(current: current, trigger: .launch, preferences: UpdatePreferences(defaults: scratchDefaults()), now: now)
        guard case .silentFailure(.network) = report else { Issue.record("expected silent network failure, got \(report)"); return }
    }

    @Test func manualFailuresAreReported() async {
        let prefs = UpdatePreferences(defaults: scratchDefaults())
        serve(tag: "v0.3.0", status: 404)
        #expect(await checker().check(current: current, trigger: .manual, preferences: prefs, now: now) == .failed(.httpStatus(404)))
        StubProtocol.install { _ in .failure(URLError(.timedOut)) }
        guard case .failed(.network) = await checker().check(current: current, trigger: .manual, preferences: prefs, now: now) else {
            Issue.record("expected reported network failure"); return
        }
        StubProtocol.install { _ in .data(Data("<html>".utf8), status: 200) }
        guard case .failed(.invalidResponse) = await checker().check(current: current, trigger: .manual, preferences: prefs, now: now) else {
            Issue.record("expected invalid response"); return
        }
    }

    @Test func userMessagesAreFriendly() {
        #expect(UpdateError.httpStatus(404).userMessage.contains("No Mira release"))
        #expect(UpdateError.network("x").userMessage.contains("internet"))
        #expect(UpdateError.signatureInvalid("x").userMessage.contains("discarded"))
    }

    @Test func scheduleHandlesClockMovingBack() {
        let schedule = CheckSchedule()
        #expect(schedule.isDue(lastCheck: nil, now: now))
        #expect(!schedule.isDue(lastCheck: now, now: now.addingTimeInterval(60)))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(7_200), now: now))   // stored date in the future
    }
}
}
