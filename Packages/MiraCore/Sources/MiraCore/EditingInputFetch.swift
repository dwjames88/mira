import Foundation
import Photos

/// Timing for a "give me the editable original" request. Photos once never called back at all,
/// so every attempt has a watchdog.
public struct EditingInputPolicy: Sendable, Equatable {
    /// No delivery and no download progress within this time from the start of an attempt: the attempt times out.
    public var firstDeliveryTimeout: Duration
    /// Once Photos reports download progress (iCloud original, network allowed), the attempt only times out
    /// when no progress and no delivery arrive for this long since the last progress event.
    public var downloadStallTimeout: Duration
    /// Total attempts (2 = one automatic retry after a timeout).
    public var attempts: Int

    public init(firstDeliveryTimeout: Duration, downloadStallTimeout: Duration, attempts: Int) {
        self.firstDeliveryTimeout = firstDeliveryTimeout
        self.downloadStallTimeout = downloadStallTimeout
        self.attempts = attempts
    }

    public static let standard = EditingInputPolicy(firstDeliveryTimeout: .seconds(8), downloadStallTimeout: .seconds(30), attempts: 2)
}

public enum EditingInputEvent: Sendable, Equatable {
    case downloading(Double)    // 0...1, from Photos' progress handler
    case retrying(attempt: Int) // 2 for the first retry
}

public enum EditingInputFailure: Error, Sendable, Equatable {
    case timedOut      // every attempt timed out
    case unavailable   // Photos delivered nil (it could not provide the input)
    case cancelled     // the calling Task was cancelled
}

/// One Photos request. A real implementation wraps `PHAsset.requestContentEditingInput`; tests fake it.
/// `progress` and `completion` may be called on any queue, any number of times (never, late, twice).
public protocol EditingInputRequesting<Input>: Sendable {
    associatedtype Input
    func start(progress: @escaping @Sendable (Double) -> Void,
               completion: @escaping @Sendable (Input?) -> Void) -> Int
    func cancel(_ requestID: Int)
}

public enum EditingInputFetch {
    /// Runs up to `policy.attempts` requests. Each attempt resumes exactly once: on the first completion, on
    /// its timeout (then it calls `cancel` with that request id), or on task cancellation (cancel too).
    /// Completions after an attempt resumed, and second completions, are ignored. A nil completion is
    /// `.unavailable`, with no retry. `onEvent` gets `.downloading` progress and `.retrying` before attempt 2+.
    public static func fetch<R: EditingInputRequesting>(
        _ requester: R, policy: EditingInputPolicy = .standard,
        onEvent: @escaping @Sendable (EditingInputEvent) -> Void = { _ in }
    ) async throws(EditingInputFailure) -> R.Input {
        try await fetch(requester, policy: policy, timer: DispatchEditingInputTimer(), onEvent: onEvent)
    }

    /// The same, against an injectable timer (tests drive a manual one, so no wall-clock timing is involved).
    static func fetch<R: EditingInputRequesting>(
        _ requester: R, policy: EditingInputPolicy, timer: some EditingInputTimer,
        onEvent: @escaping @Sendable (EditingInputEvent) -> Void = { _ in }
    ) async throws(EditingInputFailure) -> R.Input {
        let total = max(1, policy.attempts)
        for attempt in 1...total {
            if Task.isCancelled { throw .cancelled }
            if attempt > 1 { onEvent(.retrying(attempt: attempt)) }
            switch await runAttempt(requester, policy: policy, timer: timer, onEvent: onEvent) {
            case .delivered(let box): return box.value
            case .noInput: throw .unavailable
            case .cancelled: throw .cancelled
            case .timedOut: continue
            }
        }
        throw .timedOut
    }

    // MARK: Internals

    private struct Box<T>: @unchecked Sendable { let value: T }

    private enum Outcome<T>: Sendable {
        case delivered(Box<T>), noInput, timedOut, cancelled
    }

    /// Lock-protected state of one attempt. `resume` wins exactly once.
    private final class Attempt<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var continuation: CheckedContinuation<Outcome<T>, Never>?
        private var pending: Outcome<T>?
        private var requestID: Int?
        private var lastProgress: Duration?
        let start: Duration
        init(start: Duration) { self.start = start }

        var isResumed: Bool { lock.withLock { resumed } }

        /// False when the attempt already resumed (cancelled before it began).
        func install(_ c: CheckedContinuation<Outcome<T>, Never>) -> Bool {
            let early: Outcome<T>? = lock.withLock {
                if let pending { return pending }
                continuation = c
                return nil
            }
            if let early { c.resume(returning: early); return false }
            return true
        }

        /// Returns the request id to cancel when a non-delivery outcome wins and the id is known.
        /// `won` is false when the attempt had already resumed.
        func resume(_ outcome: Outcome<T>) -> (won: Bool, cancelID: Int?) {
            let (won, c, id) = lock.withLock { () -> (Bool, CheckedContinuation<Outcome<T>, Never>?, Int?) in
                if resumed { return (false, nil, nil) }
                resumed = true
                let c = continuation
                continuation = nil
                if c == nil { pending = outcome }
                switch outcome {
                case .timedOut, .cancelled:
                    abandoned = true
                    return (true, c, requestID)
                default: return (true, c, nil)
                }
            }
            c?.resume(returning: outcome)
            return (won, id)
        }

        /// True when the id arrives after the attempt was abandoned (timeout or cancel): cancel it now.
        func setID(_ id: Int) -> Bool {
            lock.withLock {
                requestID = id
                return abandoned
            }
        }
        private var abandoned = false

        /// False when the attempt already resumed.
        func noteProgress(at now: Duration) -> Bool {
            lock.withLock {
                guard !resumed else { return false }
                lastProgress = now
                return true
            }
        }

        func deadline(_ policy: EditingInputPolicy) -> Duration {
            lock.withLock {
                if let lastProgress { return lastProgress + policy.downloadStallTimeout }
                return start + policy.firstDeliveryTimeout
            }
        }
    }

    private static func runAttempt<R: EditingInputRequesting>(
        _ requester: R, policy: EditingInputPolicy, timer: some EditingInputTimer,
        onEvent: @escaping @Sendable (EditingInputEvent) -> Void
    ) async -> Outcome<R.Input> {
        let state = Attempt<R.Input>(start: timer.now())

        // Resolves the attempt; on a timeout or cancel, cancels the Photos request (now or once its id is known).
        @Sendable func finish(_ outcome: Outcome<R.Input>) {
            let result = state.resume(outcome)
            if result.won {
                switch outcome {
                case .timedOut, .cancelled:
                    if let id = result.cancelID { requester.cancel(id) }
                default: break
                }
            }
        }

        // The watchdog is a timer callback, not a Task: the backstop has to fire even when the cooperative pool
        // is saturated. Each firing re-reads the deadline (progress moves it) and re-arms itself.
        @Sendable func arm() {
            timer.schedule(after: max(.zero, state.deadline(policy) - timer.now())) {
                if state.isResumed { return }
                if state.deadline(policy) <= timer.now() { finish(.timedOut) } else { arm() }
            }
        }
        arm()

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<R.Input>, Never>) in
                guard state.install(continuation) else { return }
                let id = requester.start(
                    progress: { @Sendable value in
                        if state.noteProgress(at: timer.now()) { onEvent(.downloading(value)) }
                    },
                    completion: { @Sendable input in
                        _ = state.resume(input.map { .delivered(Box(value: $0)) } ?? .noInput)
                    })
                if state.setID(id) { requester.cancel(id) }
            }
        } onCancel: {
            finish(.cancelled)
        }
        return outcome
    }
}

/// `PHAsset.requestContentEditingInput` as an `EditingInputRequesting`. Every closure handed to Photos
/// is built here, nonisolated and `@Sendable` (Photos calls back on its own queues).
public struct PhotoKitEditingInputRequester: EditingInputRequesting, @unchecked Sendable {
    public typealias Input = PHContentEditingInput
    private struct AssetBox: @unchecked Sendable { let asset: PHAsset }
    private let box: AssetBox

    public init(asset: PHAsset) { box = AssetBox(asset: asset) }

    nonisolated public func start(progress: @escaping @Sendable (Double) -> Void,
                                  completion: @escaping @Sendable (PHContentEditingInput?) -> Void) -> Int {
        let options = PHContentEditingInputRequestOptions()
        options.canHandleAdjustmentData = { @Sendable data in MiraAdjustment.canHandle(data) }
        options.isNetworkAccessAllowed = true
        options.progressHandler = { @Sendable value, _ in progress(value) }
        let id = box.asset.requestContentEditingInput(with: options) { @Sendable input, _ in completion(input) }
        return Int(id)
    }

    nonisolated public func cancel(_ requestID: Int) {
        box.asset.cancelContentEditingInputRequest(PHContentEditingInputRequestID(requestID))
    }
}

/// A monotonic clock plus one-shot scheduling, so the watchdog can be driven without wall-clock time in tests.
protocol EditingInputTimer: Sendable {
    /// Time since an arbitrary fixed origin.
    func now() -> Duration
    func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void)
}

/// `ContinuousClock` plus a private Dispatch queue (independent of the Swift concurrency pool).
struct DispatchEditingInputTimer: EditingInputTimer {
    private let queue = DispatchQueue(label: "mira.editing-input-watchdog", qos: .userInitiated)
    private let origin = ContinuousClock.now

    func now() -> Duration { ContinuousClock.now - origin }

    func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void) {
        let (seconds, atto) = delay.components
        let nanos = Int(seconds) * 1_000_000_000 + Int(atto / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos) + .milliseconds(1), execute: work)
    }
}

/// Status-line copy for an open in progress, shared by the Mac and iOS apps (mono caps, like every status line).
public enum EditingInputStatus {
    public static let opening = "OPENING"
    public static let retrying = "OPENING \u{00B7} TRYING AGAIN"

    /// "DOWNLOADING FROM ICLOUD · 42%" for progress, the retry line for a retry.
    public static func text(for event: EditingInputEvent) -> String {
        switch event {
        case .downloading(let p):
            let percent = Int((min(max(p, 0), 1) * 100).rounded())
            return "DOWNLOADING FROM ICLOUD \u{00B7} \(percent)%"
        case .retrying: return retrying
        }
    }
}
