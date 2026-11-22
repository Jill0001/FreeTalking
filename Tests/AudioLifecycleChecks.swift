import Foundation
import AVFoundation

final class FakeCapture: AudioCapturing {
    let startGate = DispatchSemaphore(value: 0)
    let stopGate = DispatchSemaphore(value: 0)
    var blockStart = false
    var blockStop = false
    var failStart = false
    var outputURL = URL(fileURLWithPath: "/test/closed.wav")
    private let lock = NSLock()
    private var events: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func start(sessionID: UUID, selectedUID: String, previewAudio: ((AVAudioPCMBuffer) -> Void)?, levels: @escaping (Float) -> Void) throws {
        precondition(!Thread.isMainThread, "Capture must not initialize on the UI thread")
        lock.lock(); events.append("start"); lock.unlock()
        if blockStart { startGate.wait() }
        if failStart { throw NSError(domain: "test", code: 1) }
    }
    func stop() -> URL? {
        precondition(!Thread.isMainThread, "Capture must not stop on the UI thread")
        lock.lock(); events.append("stop"); lock.unlock()
        if blockStop { stopGate.wait() }
        return outputURL
    }
}

@main struct AudioLifecycleChecks {
    static func wait(_ condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), message)
    }
    static func manager(_ capture: FakeCapture, timeout: TimeInterval = 1) -> AudioManager {
        AudioManager(capture: capture, operationTimeout: timeout, requestPermission: false)
    }
    static func main() {
        // A blocked initializer returns control immediately, times out once, and
        // cannot create a second engine while the first call remains blocked.
        let slow = FakeCapture(); slow.blockStart = true
        let a = manager(slow, timeout: 0.05)
        var starts = 0
        a.startRecording { result in
            precondition(Thread.isMainThread)
            if case .success = result { preconditionFailure("Expected timeout") }
            starts += 1
        }
        wait({ starts == 1 }, "Blocked start must time out without freezing main")
        precondition(a.isBusy && !a.isRecording)
        a.startRecording { result in
            if case .success = result { preconditionFailure("Busy start accepted") }
        }
        precondition(slow.calls == ["start"])
        slow.startGate.signal()
        wait({ !a.isBusy }, "Late start must be cleaned up")
        precondition(starts == 1 && slow.calls == ["start", "stop"])

        // Cancellation while starting suppresses late success and drains cleanup.
        let cancelled = FakeCapture(); cancelled.blockStart = true
        let b = manager(cancelled)
        var cancelledCallbacks = 0
        b.startRecording { result in
            if case .success = result { preconditionFailure("Cancelled start succeeded") }
            cancelledCallbacks += 1
        }
        wait({ cancelled.calls == ["start"] }, "Start not entered")
        b.cancelStartingRecording()
        precondition(cancelledCallbacks == 1)
        cancelled.startGate.signal()
        wait({ !b.isBusy }, "Cancelled start did not clean up")
        precondition(!b.isRecording && cancelledCallbacks == 1)

        // Stop is asynchronous and publishes the file only after it is closed.
        let normal = FakeCapture(); normal.blockStop = true
        let c = manager(normal)
        c.startRecording { _ in }
        wait({ c.isRecording }, "Recording never started")
        var stopped = false
        c.stopRecording { result in
            precondition(Thread.isMainThread)
            guard case .success(let url) = result else { preconditionFailure("Stop failed"); }
            precondition(url?.lastPathComponent == "closed.wav")
            stopped = true
        }
        wait({ normal.calls == ["start", "stop"] }, "Stop not entered")
        precondition(!stopped && c.isBusy && !c.isRecording)
        normal.stopGate.signal()
        wait({ stopped && !c.isBusy }, "Stop completion missing")

        // A failing start cleans up and permits another attempt.
        let broken = FakeCapture(); broken.failStart = true
        let d = manager(broken)
        var failed = false
        d.startRecording { result in if case .failure = result { failed = true } }
        wait({ failed && !d.isBusy }, "Failure did not reset state")
        precondition(broken.calls == ["start", "stop"])
        broken.failStart = false
        d.startRecording { _ in }
        wait({ d.isRecording }, "Retry after failure failed")
        d.stopRecording { _ in }
        wait({ !d.isBusy }, "Retry stop failed")

        // A stop timeout must not release ownership of the blocked engine.
        let stuckStop = FakeCapture(); stuckStop.blockStop = true
        let e = manager(stuckStop, timeout: 0.05)
        e.startRecording { _ in }
        wait({ e.isRecording }, "Start before stop timeout failed")
        var stopCallbacks = 0
        e.stopRecording { result in
            if case .success = result { preconditionFailure("Expected stop timeout") }
            stopCallbacks += 1
        }
        wait({ stopCallbacks == 1 }, "Stop failed to time out")
        precondition(e.isBusy)
        stuckStop.stopGate.signal()
        wait({ !e.isBusy }, "Late stop did not reset state")
        precondition(stopCallbacks == 1)
        // Discard still deletes the file if stopping finishes after the deadline.
        let discard = FakeCapture(); discard.blockStop = true
        discard.outputURL = URL(fileURLWithPath: "tmp/audio-lifecycle/discard.wav")
        try! Data([1, 2, 3]).write(to: discard.outputURL)
        let f = manager(discard, timeout: 0.05)
        f.startRecording { _ in }
        wait({ f.isRecording }, "Discard setup failed")
        var discardTimedOut = false
        f.stopRecording(discard: true) { result in
            if case .failure = result { discardTimedOut = true }
        }
        wait({ discardTimedOut }, "Discard did not time out")
        discard.stopGate.signal()
        wait({ !f.isBusy }, "Discard did not recover")
        precondition(!FileManager.default.fileExists(atPath: discard.outputURL.path))
        print("PASS: discard after timeout; blocked start, duplicate start, cancellation, asynchronous stop, failure/retry, stop timeout")
    }
}
