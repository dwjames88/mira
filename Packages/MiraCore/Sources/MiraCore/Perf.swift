import Foundation
import os

/// `os_signpost` intervals for Instruments (subsystem `com.fieldframes.mira`, category `perf`).
///
/// Names in use: "preview render", "thumbnail batch", "source load", "export",
/// "grid thumbnail request".
public enum Perf {
    public static let subsystem = "com.fieldframes.mira"
    public static let category = "perf"
    public static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Runs `body` inside a signpost interval called `name`.
    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Begins an interval for work that spans several calls; pass the result to `end`.
    public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
