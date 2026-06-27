import Foundation

public enum AutoApplyCoordinator {
    public struct State: Equatable, Sendable {
        public var needsAutoApply: Bool
        public var attemptsRemaining: Int

        public init(needsAutoApply: Bool = false, attemptsRemaining: Int = 3) {
            self.needsAutoApply = needsAutoApply
            self.attemptsRemaining = attemptsRemaining
        }
    }

    public static let maxAttempts = 3

    public static func onDisconnect(_ state: inout State) {
        state.needsAutoApply = false
        state.attemptsRemaining = maxAttempts
    }

    public static func onConnect(autoReapplyEnabled: Bool, state: inout State) {
        guard autoReapplyEnabled else { return }
        state.needsAutoApply = true
        state.attemptsRemaining = maxAttempts
    }

    public static func shouldAttemptApply(
        state: State,
        autoReapplyEnabled: Bool,
        hasProfile: Bool
    ) -> Bool {
        autoReapplyEnabled && hasProfile && state.needsAutoApply && state.attemptsRemaining > 0
    }

    public static func onApplySuccess(_ state: inout State) {
        state.needsAutoApply = false
    }

    public static func onApplyFailure(_ state: inout State) {
        state.attemptsRemaining = max(0, state.attemptsRemaining - 1)
        if state.attemptsRemaining == 0 {
            state.needsAutoApply = false
        }
    }
}
