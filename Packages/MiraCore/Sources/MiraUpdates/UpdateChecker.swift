import Foundation
import os

public enum UpdateTrigger: Sendable { case launch, manual }

/// What a check found.
public enum CheckReport: Sendable, Equatable {
    /// Automatic check skipped: switched off in Settings, or ran less than a day ago.
    case notDue
    case upToDate(current: SemanticVersion, latest: SemanticVersion)
    case available(Release)
    /// A newer release the user chose to skip. Only automatic checks report this (manual checks show it).
    case skipped(Release)
    /// A manual check failed: tell the user.
    case failed(UpdateError)
    /// An automatic check failed: log only.
    case silentFailure(UpdateError)
}

/// Fetches the latest GitHub release and decides whether it is news.
public struct UpdateChecker: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/dwjames88/mira/releases/latest")!

    private static let logger = Logger(subsystem: "com.fieldframes.mira", category: "updates")

    public var session: URLSession
    public var endpoint: URL
    public var userAgent: String
    public var schedule: CheckSchedule

    public init(session: URLSession = .shared, endpoint: URL = UpdateChecker.latestReleaseURL,
                userAgent: String = "Mira-Updater", schedule: CheckSchedule = CheckSchedule()) {
        self.session = session
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.schedule = schedule
    }

    /// `GET releases/latest`. Throws `UpdateError`.
    public func fetchLatest() async throws -> Release {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw UpdateError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw UpdateError.cancelled
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidResponse("not an HTTP response") }
        guard http.statusCode == 200 else { throw UpdateError.httpStatus(http.statusCode) }
        return try Release.decode(data)
    }

    /// Runs one check. Automatic (launch) checks honor the switch and the 24 h throttle and fail silently;
    /// manual checks ignore both and always report. `now` is injectable for tests.
    public func check(current: SemanticVersion, trigger: UpdateTrigger, preferences: UpdatePreferences,
                      now: Date = Date()) async -> CheckReport {
        if trigger == .launch {
            guard preferences.automaticChecksEnabled, schedule.isDue(lastCheck: preferences.lastCheck, now: now) else {
                return .notDue
            }
        }
        let release: Release
        do {
            release = try await fetchLatest()
        } catch {
            let failure = error as? UpdateError ?? .network(error.localizedDescription)
            Self.logger.info("Update check (\(trigger == .launch ? "launch" : "manual")) failed: \(failure.description, privacy: .public)")
            return trigger == .launch ? .silentFailure(failure) : .failed(failure)
        }
        preferences.lastCheck = now
        guard release.version > current, !release.isPrerelease else {
            return .upToDate(current: current, latest: release.version)
        }
        if trigger == .launch, preferences.skippedVersion == release.version { return .skipped(release) }
        return .available(release)
    }
}
