import Testing

/// Lets one test that touches camera RAW (`CIRAWFilter`: opening, reading its properties, decoding) run at a time in the
/// whole test process, without parking a thread while it waits.
///
/// RawCamera answers every RAW request through libdispatch workers. Under `swift test` (parallel) the cooperative
/// pool has one thread per core; when several RAW tests sit in it at once, together with tests parked on a context
/// lock, no worker gets scheduled and every RAW call waits forever (see `ContextStressTests`). A test waiting here
/// is suspended, so it holds no pool thread.
struct RawExclusiveTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        await RawSlot.shared.acquire()
        do { try await function() } catch {
            await RawSlot.shared.release()
            throw error
        }
        await RawSlot.shared.release()
    }
}

extension Trait where Self == RawExclusiveTrait {
    static var rawExclusive: Self { Self() }
}

/// A first-in first-out async mutex.
actor RawSlot {
    static let shared = RawSlot()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
