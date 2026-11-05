import Foundation
import Testing
@testable import MiraCore

/// A timer the test advances by hand: no wall-clock time is involved, so a loaded machine cannot change an
/// outcome. Due work runs in time order inside `advance`, with `now()` set to each item's due time.
final class ManualTimer: EditingInputTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    private var seq = 0
    private var items: [(due: Duration, seq: Int, work: @Sendable () -> Void)] = []

    func now() -> Duration { lock.withLock { time } }

    func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            seq += 1
            items.append((time + max(.zero, delay), seq, work))
        }
    }

    func advance(by step: Duration) {
        let target = lock.withLock { time + step }
        while true {
            let next: (@Sendable () -> Void)? = lock.withLock {
                guard let i = items.indices.filter({ items[$0].due <= target })
                    .min(by: { (items[$0].due, items[$0].seq) < (items[$1].due, items[$1].seq) }) else { return nil }
                let item = items.remove(at: i)
                time = max(time, item.due)
                return item.work
            }
            guard let next else { break }
            next()
        }
        lock.withLock { time = max(time, target) }
    }
}

/// Scripted fake: each `start` consumes the next behaviour. Thread-safe; records starts, cancels and events.
/// Deliveries are scheduled on the manual timer.
final class FakeRequester: EditingInputRequesting, @unchecked Sendable {
    typealias Input = String
    enum Behaviour {
        case never
        case deliver(String)                 // synchronously inside start
        case deliverAfter(Duration, String)  // later, on the manual timer
        case deliverTwice(String, String)    // sync first, then the second twice, 20 ms later
        case nilInput
        case progressThenDeliver(ticks: Int, every: Duration, value: String)
        case progressThenSilence(ticks: Int, every: Duration)
    }
    private let lock = NSLock()
    private let timer: ManualTimer
    private var script: [Behaviour]
    private var _starts = 0, _cancels: [Int] = [], _events: [EditingInputEvent] = []
    init(_ script: [Behaviour], timer: ManualTimer) { self.script = script; self.timer = timer }

    var starts: Int { lock.withLock { _starts } }
    var cancels: [Int] { lock.withLock { _cancels } }
    var events: [EditingInputEvent] { lock.withLock { _events } }
    func record(_ e: EditingInputEvent) { lock.withLock { _events.append(e) } }

    func start(progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (String?) -> Void) -> Int {
        let (id, behaviour): (Int, Behaviour) = lock.withLock {
            _starts += 1
            return (_starts, script.isEmpty ? .never : script.removeFirst())
        }
        switch behaviour {
        case .never: break
        case .deliver(let v): completion(v)
        case .deliverAfter(let d, let v): timer.schedule(after: d) { completion(v) }
        case .deliverTwice(let a, let b):
            completion(a)
            timer.schedule(after: .milliseconds(20)) { completion(b); completion(b) }
        case .nilInput: completion(nil)
        case .progressThenDeliver(let ticks, let every, let v):
            for i in 1...ticks { timer.schedule(after: every * i) { progress(Double(i) / Double(ticks)) } }
            timer.schedule(after: every * ticks) { completion(v) }
        case .progressThenSilence(let ticks, let every):
            for i in 1...ticks { timer.schedule(after: every * i) { progress(Double(i) / Double(ticks)) } }
        }
        return id
    }

    func cancel(_ requestID: Int) { lock.withLock { _cancels.append(requestID) } }
}

/// One fetch running in a Task, with the fake, the manual timer and helpers to step virtual time.
final class Harness: @unchecked Sendable {
    let timer = ManualTimer()
    let fake: FakeRequester
    private let lock = NSLock()
    private var task: Task<Result<String, EditingInputFailure>, Never>?

    static let policy = EditingInputPolicy(firstDeliveryTimeout: .seconds(1), downloadStallTimeout: .seconds(3), attempts: 2)

    init(_ script: [FakeRequester.Behaviour], policy: EditingInputPolicy = Harness.policy) {
        fake = FakeRequester(script, timer: timer)
        let fake = fake, timer = timer
        let t = Task { () -> Result<String, EditingInputFailure> in
            do throws(EditingInputFailure) {
                return .success(try await EditingInputFetch.fetch(fake, policy: policy, timer: timer, onEvent: { fake.record($0) }))
            } catch { return .failure(error) }
        }
        lock.withLock { task = t }
    }

    /// Waits (real time, polling) for a condition; cancels the fetch and records an issue after 120 s so a bug
    /// fails the test instead of hanging it.
    func wait(_ what: String, sourceLocation: SourceLocation = #_sourceLocation, until condition: () -> Bool) async {
        var spins = 0
        while !condition() {
            spins += 1
            if spins > 60_000 {
                Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
                cancel()
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func cancel() { lock.withLock { task }?.cancel() }
    func result() async -> Result<String, EditingInputFailure> { await lock.withLock { task }!.value }
}

@Suite("EditingInputFetch", .timeLimit(.minutes(1)))
struct EditingInputFetchTests {
    @Test func deliversAtOnce() async {
        let h = Harness([.deliverAfter(.milliseconds(5), "A")])
        await h.wait("start") { h.fake.starts == 1 }
        h.timer.advance(by: .milliseconds(5))
        #expect(await h.result() == .success("A"))
        #expect(h.fake.starts == 1)
        #expect(h.fake.cancels.isEmpty)
    }

    @Test func neverCallsBackTimesOutAfterTwoAttempts() async {
        let h = Harness([.never, .never])
        await h.wait("attempt 1") { h.fake.starts == 1 }
        h.timer.advance(by: .seconds(1))                      // first timeout
        await h.wait("attempt 2") { h.fake.starts == 2 }
        #expect(h.fake.cancels == [1])
        h.timer.advance(by: .seconds(1))                      // second timeout
        #expect(await h.result() == .failure(.timedOut))
        #expect(h.fake.starts == 2)
        #expect(h.fake.cancels == [1, 2])
        #expect(h.fake.events == [.retrying(attempt: 2)])
        #expect(h.timer.now() == .seconds(2))                 // two first-delivery timeouts, no more
    }

    @Test func retrySucceeds() async {
        let h = Harness([.never, .deliverAfter(.milliseconds(5), "B")])
        await h.wait("attempt 1") { h.fake.starts == 1 }
        h.timer.advance(by: .seconds(1))
        await h.wait("attempt 2") { h.fake.starts == 2 }
        h.timer.advance(by: .milliseconds(5))
        #expect(await h.result() == .success("B"))
        #expect(h.fake.cancels == [1])
        #expect(h.fake.events == [.retrying(attempt: 2)])
    }

    @Test func lateDeliveryIsIgnoredWhenRetryNeverDelivers() async {
        // Attempt 1 times out at 1 s and delivers "late" at 1.5 s; attempt 2 (started at 1 s) never delivers.
        let h = Harness([.deliverAfter(.milliseconds(1500), "late"), .never])
        await h.wait("attempt 1") { h.fake.starts == 1 }
        h.timer.advance(by: .seconds(1))
        await h.wait("attempt 2") { h.fake.starts == 2 }
        h.timer.advance(by: .milliseconds(500))               // the late delivery lands now
        #expect(h.fake.cancels == [1])
        h.timer.advance(by: .milliseconds(500))               // attempt 2 times out at 2 s
        #expect(await h.result() == .failure(.timedOut))
        #expect(h.fake.cancels == [1, 2])
    }

    @Test func lateDeliveryIsIgnoredWhenRetryDelivers() async {
        // "late" lands at 1.5 s while attempt 2 waits; attempt 2 delivers "B" at 1.9 s.
        let h = Harness([.deliverAfter(.milliseconds(1500), "late"), .deliverAfter(.milliseconds(900), "B")])
        await h.wait("attempt 1") { h.fake.starts == 1 }
        h.timer.advance(by: .seconds(1))
        await h.wait("attempt 2") { h.fake.starts == 2 }
        h.timer.advance(by: .milliseconds(500))
        h.timer.advance(by: .milliseconds(400))
        #expect(await h.result() == .success("B"))
        #expect(h.fake.cancels == [1])
    }

    @Test func completionTwiceReturnsFirst() async {
        let h = Harness([.deliverTwice("first", "second")])
        #expect(await h.result() == .success("first"))
        h.timer.advance(by: .milliseconds(20))                // the duplicate, asynchronous calls land
        #expect(h.fake.starts == 1)
        #expect(h.fake.cancels.isEmpty)
    }

    @Test func synchronousCompletionInsideStart() async {
        let h = Harness([.deliver("S")])
        #expect(await h.result() == .success("S"))
        #expect(h.fake.cancels.isEmpty)
        h.timer.advance(by: .seconds(10))                     // the abandoned watchdog does nothing
        #expect(h.fake.cancels.isEmpty)
    }

    @Test func nilIsUnavailableWithoutRetry() async {
        let h = Harness([.nilInput, .deliver("never used")])
        #expect(await h.result() == .failure(.unavailable))
        #expect(h.fake.starts == 1)
        #expect(h.fake.cancels.isEmpty)
        #expect(h.fake.events.isEmpty)
    }

    @Test func progressExtendsTheDeadline() async {
        // Progress every 400 ms for 3.2 s: far past the 1 s first timeout, never a 3 s gap.
        let h = Harness([.progressThenDeliver(ticks: 8, every: .milliseconds(400), value: "D")])
        await h.wait("start") { h.fake.starts == 1 }
        for _ in 0..<8 { h.timer.advance(by: .milliseconds(400)) }
        #expect(await h.result() == .success("D"))
        #expect(h.fake.starts == 1)
        #expect(h.fake.cancels.isEmpty)
        #expect(h.fake.events.count == 8)
        #expect(h.fake.events.first == .downloading(0.125))
        #expect(h.fake.events.last == .downloading(1))
    }

    @Test func progressThenSilenceTimesOutAtStallTimeout() async {
        // Last progress at 800 ms, so the timeout is at 3.8 s, not at the 1 s first timeout.
        let policy = EditingInputPolicy(firstDeliveryTimeout: .seconds(1), downloadStallTimeout: .seconds(3), attempts: 1)
        let h = Harness([.progressThenSilence(ticks: 2, every: .milliseconds(400))], policy: policy)
        await h.wait("start") { h.fake.starts == 1 }
        h.timer.advance(by: .seconds(1))
        #expect(h.fake.cancels.isEmpty)                       // past the first timeout, still waiting
        h.timer.advance(by: .milliseconds(2799))
        #expect(h.fake.cancels.isEmpty)                       // 3.799 s
        h.timer.advance(by: .milliseconds(1))
        #expect(await h.result() == .failure(.timedOut))
        #expect(h.fake.cancels == [1])
        #expect(h.timer.now() == .milliseconds(3800))
    }

    @Test func taskCancellationIsPromptAndCancelsTheRequest() async {
        let h = Harness([.never])
        await h.wait("start") { h.fake.starts == 1 }
        h.cancel()                                            // no time passes at all
        #expect(await h.result() == .failure(.cancelled))
        #expect(h.fake.cancels == [1])
        #expect(h.fake.starts == 1)                           // no retry after a cancel
        #expect(h.timer.now() == .zero)
    }

    @Test func cancelledBeforeStartingNeverStartsARequest() async {
        let h = Harness([.never])
        h.cancel()
        #expect(await h.result() == .failure(.cancelled))
        #expect(h.fake.cancels.count == h.fake.starts)        // whatever started was cancelled
    }

    @Test func standardPolicyValues() {
        let p = EditingInputPolicy.standard
        #expect(p.firstDeliveryTimeout == .seconds(8))
        #expect(p.downloadStallTimeout == .seconds(30))
        #expect(p.attempts == 2)
    }

    /// The real Dispatch timer, end to end with tiny wall-clock times, and only loose bounds.
    @Test func realTimerTimesOutWithoutACallback() async {
        let fake = FakeRequester([.never, .never], timer: ManualTimer())
        let policy = EditingInputPolicy(firstDeliveryTimeout: .milliseconds(30), downloadStallTimeout: .milliseconds(60), attempts: 2)
        let task = Task { () -> Result<String, EditingInputFailure> in
            do throws(EditingInputFailure) { return .success(try await EditingInputFetch.fetch(fake, policy: policy)) }
            catch { return .failure(error) }
        }
        let result = await task.value
        #expect(result == .failure(.timedOut))
        #expect(fake.cancels == [1, 2])
    }
}

@Suite("Editing input status copy")
struct EditingInputStatusTests {
    @Test func downloadingShowsClampedPercent() {
        #expect(EditingInputStatus.text(for: .downloading(0.424)) == "DOWNLOADING FROM ICLOUD \u{00B7} 42%")
        #expect(EditingInputStatus.text(for: .downloading(1.7)) == "DOWNLOADING FROM ICLOUD \u{00B7} 100%")
        #expect(EditingInputStatus.text(for: .downloading(-1)) == "DOWNLOADING FROM ICLOUD \u{00B7} 0%")
    }
    @Test func retryingLine() {
        #expect(EditingInputStatus.text(for: .retrying(attempt: 2)) == "OPENING \u{00B7} TRYING AGAIN")
    }
}
