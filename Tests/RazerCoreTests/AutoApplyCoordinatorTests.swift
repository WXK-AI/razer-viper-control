import XCTest
@testable import RazerCore

final class AutoApplyCoordinatorTests: XCTestCase {
    func testConnectSetsNeedsAutoApply() {
        var state = AutoApplyCoordinator.State()
        AutoApplyCoordinator.onConnect(autoReapplyEnabled: true, state: &state)
        XCTAssertTrue(state.needsAutoApply)
        XCTAssertEqual(state.attemptsRemaining, AutoApplyCoordinator.maxAttempts)
    }

    func testDisconnectResetsState() {
        var state = AutoApplyCoordinator.State(needsAutoApply: true, attemptsRemaining: 1)
        AutoApplyCoordinator.onDisconnect(&state)
        XCTAssertFalse(state.needsAutoApply)
        XCTAssertEqual(state.attemptsRemaining, AutoApplyCoordinator.maxAttempts)
    }

    func testShouldAttemptApplyRequiresAllConditions() {
        let ready = AutoApplyCoordinator.State(needsAutoApply: true, attemptsRemaining: 2)
        XCTAssertTrue(AutoApplyCoordinator.shouldAttemptApply(state: ready, autoReapplyEnabled: true, hasProfile: true))
        XCTAssertFalse(AutoApplyCoordinator.shouldAttemptApply(state: ready, autoReapplyEnabled: false, hasProfile: true))
        XCTAssertFalse(AutoApplyCoordinator.shouldAttemptApply(state: ready, autoReapplyEnabled: true, hasProfile: false))

        let exhausted = AutoApplyCoordinator.State(needsAutoApply: true, attemptsRemaining: 0)
        XCTAssertFalse(AutoApplyCoordinator.shouldAttemptApply(state: exhausted, autoReapplyEnabled: true, hasProfile: true))
    }

    func testFailureRetriesUntilBudgetExhausted() {
        var state = AutoApplyCoordinator.State(needsAutoApply: true, attemptsRemaining: 3)
        AutoApplyCoordinator.onApplyFailure(&state)
        XCTAssertTrue(state.needsAutoApply)
        XCTAssertEqual(state.attemptsRemaining, 2)

        AutoApplyCoordinator.onApplyFailure(&state)
        XCTAssertEqual(state.attemptsRemaining, 1)

        AutoApplyCoordinator.onApplyFailure(&state)
        XCTAssertFalse(state.needsAutoApply)
        XCTAssertEqual(state.attemptsRemaining, 0)
    }

    func testSuccessClearsPendingApply() {
        var state = AutoApplyCoordinator.State(needsAutoApply: true, attemptsRemaining: 2)
        AutoApplyCoordinator.onApplySuccess(&state)
        XCTAssertFalse(state.needsAutoApply)
    }
}
