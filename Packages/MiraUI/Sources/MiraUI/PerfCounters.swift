import Foundation

/// How many times key views have evaluated their `body`. Read only by the opt-in UI performance
/// test (`MIRA_PERF=1`); the cost is one integer increment on the main actor.
@MainActor
enum PerfCounters {
    static var filmStrip = 0
    static var filmCard = 0
    static var panels = 0
}
