import Foundation

/// What the terminal is doing with its SSH socket. The SwiftTerm view and the typed-input buffer
/// are not part of this state: a scene change or a dead socket never throws them away.
public struct SessionLinkMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case live
        case backoff(attempt: Int, delaySeconds: Int)
        case waitingForPath
        case failed(retryable: Bool)
        case ended
    }

    public enum Event: Equatable, Sendable {
        case connectSucceeded
        case connectFailed(retryable: Bool)
        case socketClosed
        case pingMissed
        case pingSucceeded
        case sceneBackground
        case sceneForeground
        case networkChanged
        case waitElapsed
        case userReconnect
        case userClose
        case pathUnavailable
        case pathAvailable
        case cleanExit
    }

    public enum Effect: Equatable, Sendable {
        /// Open a socket and attach the same remote session. Does not clear the terminal.
        case openSocket
        /// Close the SSH socket only.
        case closeSocket
        case scheduleWait(Int)
        case cancelWait
        case beginBackgroundTask
        case endBackgroundTask
        /// The remote session is attached again; deliver keystrokes typed during the gap.
        case flushInput
        case probeSocket
    }

    public static let backoffSchedule = [1, 2, 4, 8, 16, 30]
    public static let maxAttempts = 12
    public static let missesBeforeDrop = 2

    public private(set) var state: State
    public private(set) var attempt: Int
    public private(set) var backgrounded: Bool
    public private(set) var missedPings: Int
    public private(set) var probing: Bool
    /// This session asked for background time. Only that session releases it.
    private var holdsBackgroundTask = false

    public init() {
        state = .connecting
        attempt = 0
        backgrounded = false
        missedPings = 0
        probing = false
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .connectSucceeded:
            return connectSucceeded()
        case .connectFailed(let retryable):
            return connectFailed(retryable: retryable)
        case .socketClosed:
            return socketClosed()
        case .pingMissed:
            return pingMissed()
        case .pingSucceeded:
            missedPings = 0
            probing = false
            return []
        case .sceneBackground:
            return sceneBackground()
        case .sceneForeground:
            return sceneForeground()
        case .networkChanged:
            return networkChanged()
        case .waitElapsed:
            return waitElapsed()
        case .userReconnect:
            return userReconnect()
        case .userClose:
            state = .ended
            probing = false
            missedPings = 0
            return releasing([.cancelWait, .closeSocket])
        case .pathUnavailable:
            return pathUnavailable()
        case .pathAvailable:
            return pathAvailable()
        case .cleanExit:
            guard case .live = state else { return [] }
            state = .ended
            probing = false
            return [.cancelWait, .closeSocket]
        }
    }

    private mutating func connectSucceeded() -> [Effect] {
        guard case .connecting = state else { return [] }
        attempt = 0
        missedPings = 0
        probing = false
        state = .live
        return [.flushInput]
    }

    private mutating func connectFailed(retryable: Bool) -> [Effect] {
        guard case .connecting = state else { return [] }
        if !retryable {
            state = .failed(retryable: false)
            return [.closeSocket]
        }
        return beginBackoff()
    }

    private mutating func socketClosed() -> [Effect] {
        switch state {
        case .live, .connecting:
            return beginBackoff()
        case .backoff, .waitingForPath, .failed, .ended:
            return []
        }
    }

    private mutating func pingMissed() -> [Effect] {
        guard case .live = state else { return [] }
        missedPings += 1
        if missedPings < Self.missesBeforeDrop { return [] }
        return beginBackoff()
    }

    private mutating func sceneBackground() -> [Effect] {
        guard !backgrounded else { return [] }
        backgrounded = true
        switch state {
        case .ended, .failed:
            return []
        case .connecting, .live, .backoff, .waitingForPath:
            holdsBackgroundTask = true
            return [.beginBackgroundTask]
        }
    }

    private mutating func sceneForeground() -> [Effect] {
        backgrounded = false
        var effects: [Effect] = []
        if holdsBackgroundTask {
            holdsBackgroundTask = false
            effects.append(.endBackgroundTask)
        }
        switch state {
        case .live:
            probing = true
            effects.append(.probeSocket)
        case .backoff:
            state = .connecting
            effects.append(.cancelWait)
            effects.append(.openSocket)
        case .failed(let retryable) where retryable:
            attempt = 0
            missedPings = 0
            state = .connecting
            effects.append(.openSocket)
        case .connecting, .waitingForPath, .failed, .ended:
            break
        }
        return effects
    }

    private mutating func networkChanged() -> [Effect] {
        switch state {
        case .live:
            probing = true
            return [.probeSocket]
        case .backoff:
            state = .connecting
            return [.cancelWait, .openSocket]
        case .failed(let retryable) where retryable:
            attempt = 0
            missedPings = 0
            state = .connecting
            return [.openSocket]
        case .connecting:
            // A path flap must not cancel the dial that is already in flight. Doing that
            // left the UI on "Reconnecting in 0 s (try 1)" while the next socket never finished.
            return []
        case .waitingForPath, .failed, .ended:
            return []
        }
    }

    private mutating func waitElapsed() -> [Effect] {
        guard case .backoff = state else { return [] }
        state = .connecting
        return [.openSocket]
    }

    private mutating func userReconnect() -> [Effect] {
        attempt = 0
        missedPings = 0
        probing = false
        switch state {
        case .connecting:
            return [.cancelWait, .openSocket]
        case .live, .backoff, .waitingForPath, .failed, .ended:
            state = .connecting
            return [.cancelWait, .closeSocket, .openSocket]
        }
    }

    private mutating func pathUnavailable() -> [Effect] {
        switch state {
        case .waitingForPath, .ended, .failed:
            return []
        case .connecting, .live, .backoff:
            state = .waitingForPath
            probing = false
            missedPings = 0
            return [.cancelWait, .closeSocket]
        }
    }

    private mutating func pathAvailable() -> [Effect] {
        switch state {
        case .waitingForPath:
            attempt = 0
            state = .connecting
            return [.openSocket]
        case .failed(let retryable) where retryable:
            attempt = 0
            state = .connecting
            return [.openSocket]
        case .backoff:
            state = .connecting
            return [.cancelWait, .openSocket]
        case .connecting, .live, .failed, .ended:
            return []
        }
    }

    private mutating func releasing(_ effects: [Effect]) -> [Effect] {
        guard holdsBackgroundTask else { return effects }
        holdsBackgroundTask = false
        return effects + [.endBackgroundTask]
    }

    /// One line for the session bar and the reconnect banner. A delay of 0 is not shown as "in 0 s".
    public static func reconnectLine(attempt: Int, delay: Int, error: String?) -> String {
        let base = delay > 0
            ? "Reconnecting in \(delay) s (try \(attempt))"
            : "Reconnecting (try \(attempt))"
        let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty else { return base }
        return base + ". " + reason
    }

    /// Counts one failed attempt. Twelve failures end in `.failed(retryable: true)` with no further wait.
    private mutating func beginBackoff() -> [Effect] {
        missedPings = 0
        probing = false
        attempt += 1
        if attempt >= Self.maxAttempts {
            state = .failed(retryable: true)
            return [.cancelWait, .closeSocket]
        }
        let delay = Self.backoffSchedule[min(attempt - 1, Self.backoffSchedule.count - 1)]
        state = .backoff(attempt: attempt, delaySeconds: delay)
        return [.cancelWait, .closeSocket, .scheduleWait(delay)]
    }
}
