import Foundation

/// Bounds event-tap timeout recovery so repeated failures pause remapping safely.
public struct TapDisableCircuitBreaker: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case allowRecovery
        case trip
    }

    private static let window: TimeInterval = 10
    private static let tripCount = 3

    private var disableTimes: [TimeInterval] = []
    public private(set) var isOpen = false

    public init() {}

    /// Records an event-tap disable. The third disable in a ten-second window opens the circuit.
    public mutating func recordDisable(at time: TimeInterval) -> Decision {
        guard !isOpen else { return .trip }

        disableTimes.removeAll { time - $0 >= Self.window }
        disableTimes.append(time)
        if disableTimes.count >= Self.tripCount {
            isOpen = true
            return .trip
        }
        return .allowRecovery
    }

    public mutating func reset() {
        disableTimes.removeAll()
        isOpen = false
    }
}
