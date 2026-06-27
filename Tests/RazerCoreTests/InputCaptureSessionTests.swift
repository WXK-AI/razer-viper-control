import XCTest
@testable import RazerCore

final class InputCaptureSessionTests: XCTestCase {
    func testSnapshotStartsEmpty() {
        let session = InputCaptureSession()
        XCTAssertTrue(session.snapshotEntries().isEmpty)
    }

    func testClearNotifiesCallbackWithEmptySnapshot() {
        let session = InputCaptureSession()
        let expectation = expectation(description: "entries changed")
        session.onEntriesChanged = { entries in
            XCTAssertTrue(entries.isEmpty)
            expectation.fulfill()
        }
        session.clear()
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(session.snapshotEntries().isEmpty)
    }
}
