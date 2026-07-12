import XCTest
@testable import RazerCore

final class TapDisableCircuitBreakerTests: XCTestCase {
    func testFirstTwoDisablesAllowRecoveryAndThirdTrips() {
        var breaker = TapDisableCircuitBreaker()

        XCTAssertEqual(breaker.recordDisable(at: 0), .allowRecovery)
        XCTAssertEqual(breaker.recordDisable(at: 5), .allowRecovery)
        XCTAssertEqual(breaker.recordDisable(at: 9.9), .trip)
        XCTAssertTrue(breaker.isOpen)
    }

    func testQuietTenSecondWindowResetsDisableCount() {
        var breaker = TapDisableCircuitBreaker()

        XCTAssertEqual(breaker.recordDisable(at: 0), .allowRecovery)
        XCTAssertEqual(breaker.recordDisable(at: 1), .allowRecovery)
        XCTAssertEqual(breaker.recordDisable(at: 11), .allowRecovery)
        XCTAssertFalse(breaker.isOpen)
    }

    func testOpenCircuitStaysOpenUntilReset() {
        var breaker = TapDisableCircuitBreaker()

        _ = breaker.recordDisable(at: 0)
        _ = breaker.recordDisable(at: 1)
        XCTAssertEqual(breaker.recordDisable(at: 2), .trip)
        XCTAssertEqual(breaker.recordDisable(at: 100), .trip)
        XCTAssertTrue(breaker.isOpen)

        breaker.reset()

        XCTAssertFalse(breaker.isOpen)
        XCTAssertEqual(breaker.recordDisable(at: 100), .allowRecovery)
    }
}
