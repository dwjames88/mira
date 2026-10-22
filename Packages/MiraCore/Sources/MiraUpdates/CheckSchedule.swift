import Foundation

public struct CheckSchedule: Sendable {
    public var interval: TimeInterval

    public init(interval: TimeInterval = 86_400) {
        self.interval = interval
    }

    /// Due when never checked, when the interval has elapsed, or when the stored date is more than an hour in
    /// the future (the clock moved back; otherwise the next check would be postponed indefinitely).
    public func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        if elapsed < -3_600 { return true }
        return elapsed >= interval
    }
}
