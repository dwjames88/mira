import Testing
@testable import MiraCameraKit

@Suite struct CameraStateTests {
    private func run(_ events: [CameraEvent], from s: CameraState = .idle) -> CameraState {
        var state = s
        for e in events { state.handle(e) }
        return state
    }

    @Test func startsAndRuns() {
        #expect(run([.start]) == .starting)
        #expect(run([.start, .sessionStarted]) == .running)
        #expect(run([.sessionStarted]) == .idle)
    }

    @Test func captureCountsInFlight() {
        #expect(run([.start, .sessionStarted, .captureStarted]) == .capturing(1))
        #expect(run([.start, .sessionStarted, .captureStarted, .captureStarted]) == .capturing(2))
        #expect(run([.start, .sessionStarted, .captureStarted, .captureStarted, .captureFinished]) == .capturing(1))
        #expect(run([.start, .sessionStarted, .captureStarted, .captureFinished]) == .running)
        #expect(run([.start, .sessionStarted, .captureFinished]) == .running)
        #expect(CameraState.capturing(2).inFlightCount == 2)
        #expect(CameraState.running.canCapture && CameraState.capturing(1).canCapture)
        #expect(!CameraState.starting.canCapture && !CameraState.interrupted(.unknown).canCapture)
    }

    @Test func interruptionsPauseAndResume() {
        for reason in CameraInterruption.allCases {
            let s = run([.start, .sessionStarted, .interruptionBegan(reason)])
            #expect(s == .interrupted(reason))
            #expect(!reason.displayText.isEmpty && reason.displayText == reason.displayText.uppercased())
            #expect(run([.interruptionEnded], from: s) == .running)
        }
        // From capturing, and a second interruption replaces the first.
        #expect(run([.interruptionBegan(.videoDeviceInUseByAnotherClient)], from: .capturing(2))
            == .interrupted(.videoDeviceInUseByAnotherClient))
        #expect(run([.interruptionBegan(.unknown)], from: .interrupted(.sensitiveContentMitigation)) == .interrupted(.unknown))
        // Captures finishing during an interruption do not leave it.
        #expect(run([.captureFinished, .captureStarted], from: .interrupted(.unknown)) == .interrupted(.unknown))
        #expect(run([.interruptionEnded], from: .running) == .running)
    }

    @Test func failureAndRecovery() {
        let failed = run([.start, .runtimeError("boom")])
        #expect(failed == .failed("boom"))
        #expect(failed.statusText != nil)
        #expect(run([.sessionStarted, .captureStarted], from: failed) == failed)
        #expect(run([.start, .sessionStarted], from: failed) == .running)
        #expect(run([.runtimeError("x")], from: .capturing(1)) == .failed("x"))
        #expect(run([.runtimeError("x")], from: .interrupted(.unknown)) == .failed("x"))
        #expect(run([.runtimeError("x")], from: .idle) == .idle)
    }

    @Test func stopAlwaysGoesIdle() {
        for s: CameraState in [.starting, .running, .capturing(3), .interrupted(.unknown), .failed("x"), .idle] {
            #expect(run([.stop], from: s) == .idle)
        }
    }

    @Test func interruptionCopyIsMonoCaps() {
        #expect(CameraState.interrupted(.videoDeviceInUseByAnotherClient).statusText == "CAMERA IN USE BY ANOTHER APP")
        #expect(CameraState.running.statusText == nil)
    }
}
