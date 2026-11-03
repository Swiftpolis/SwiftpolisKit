import Foundation
import Synchronization
import SwiftpolisDomain
import SwiftpolisEngines

/// Adds a Start time and End time to any engine. Engines have no clock of their own.
///
/// It looks like an ordinary engine to whoever runs it: status `scheduled` while waiting, then
/// whatever the engine says.
public final class ScheduledDownload: DownloadEngine {
    private enum Phase {
        case waiting
        case running
        case stopped
        case missed
    }

    private struct State {
        var phase = Phase.waiting
        var waitingTask: Task<Void, Error>?
        var dialWhileWaiting: Int?
    }

    private let engine: any DownloadEngine
    private let window: ScheduleWindow
    private let clock: any WallClock
    private let state = Mutex(State())

    public init(engine: any DownloadEngine, window: ScheduleWindow, clock: any WallClock) {
        self.engine = engine
        self.window = window
        self.clock = clock
    }

    public func run() async {
        await withTaskCancellationHandler {
            await perform()
        } onCancel: {
            stop()
        }
    }

    private func perform() async {
        guard await waitForStart() else { return }

        let dial = state.withLock { state -> Int? in
            guard state.phase == .waiting else { return nil }
            state.phase = .running
            return state.dialWhileWaiting
        }
        guard state.withLock({ $0.phase }) == .running else { return }
        if let dial { engine.setSpeedDial(dial) }

        // Ending the timer along with the engine is what stops a finished Download being marked
        // stopped when its End time later arrives.
        let endTimer = window.end.map { end in
            Task { [clock, engine] in
                try await clock.sleep(until: end)
                engine.stop()
            }
        }
        await engine.run()
        endTimer?.cancel()
    }

    /// Returns true when the Download should go ahead.
    private func waitForStart() async -> Bool {
        while true {
            if state.withLock({ $0.phase }) != .waiting { return false }
            switch window.decision(at: clock.now) {
            case .start:
                return true
            case .missed:
                state.withLock { $0.phase = .missed }
                return false
            case .wait(let moment):
                let task = Task { [clock] in try await clock.sleep(until: moment) }
                let isStillWaiting = state.withLock { state -> Bool in
                    state.waitingTask = task
                    return state.phase == .waiting
                }
                if !isStillWaiting { task.cancel() }
                _ = await task.result
            }
        }
    }

    public func pause() {
        if phase == .running { engine.pause() }
    }

    public func unpause() {
        if phase == .running { engine.unpause() }
    }

    public func stop() {
        let (wasRunning, waitingTask) = state.withLock { state -> (Bool, Task<Void, Error>?) in
            if state.phase == .running { return (true, nil) }
            if state.phase == .waiting { state.phase = .stopped }
            return (false, state.waitingTask)
        }
        if wasRunning {
            engine.stop()
        } else {
            waitingTask?.cancel()
        }
    }

    public func setSpeedDial(_ dial: Int) {
        let isRunning = state.withLock { state -> Bool in
            if state.phase == .running { return true }
            state.dialWhileWaiting = dial
            return false
        }
        if isRunning { engine.setSpeedDial(dial) }
    }

    public var snapshot: DownloadSnapshot {
        var snapshot = engine.snapshot
        switch phase {
        case .running:
            break
        case .waiting:
            snapshot.status = .scheduled
            snapshot.activeConnections = 0
        case .stopped:
            snapshot.status = .stopped
            snapshot.activeConnections = 0
        case .missed:
            snapshot.status = .stopped
            snapshot.activeConnections = 0
            snapshot.errorMessage = "The scheduled time passed while this Mac was asleep"
        }
        return snapshot
    }

    private var phase: Phase { state.withLock { $0.phase } }
}
