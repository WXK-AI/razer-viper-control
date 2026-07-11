import XCTest
@testable import RazerCore

final class InputCaptureDiagnosticSinkTests: XCTestCase {
    func testDisabledSinkDoesNotRecordOrEnqueue() {
        let session = InputCaptureSession(maxEntries: 50)
        let sink = InputCaptureDiagnosticSink()
        sink.update(enabled: false, session: session)

        for index in 0..<100 {
            sink.record(control: .wheelUp, disposition: .remapped, detail: "scroll-\(index)")
        }

        XCTAssertTrue(session.snapshotEntries().isEmpty)
        XCTAssertEqual(session.publicationEnqueueCount, 0)
    }

    func testBurstRecordsWithoutPerEventMainEnqueueGrowth() {
        let session = InputCaptureSession(maxEntries: 50)
        let sink = InputCaptureDiagnosticSink()
        sink.update(enabled: true, session: session)

        for index in 0..<500 {
            sink.record(control: .wheelUp, disposition: .remapped, detail: "scroll-\(index)")
        }

        XCTAssertEqual(session.snapshotEntries().count, 50)
        XCTAssertEqual(session.publicationEnqueueCount, 1)

        let settled = expectation(description: "publication drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(session.publicationEnqueueCount, 1)
        XCTAssertEqual(session.snapshotEntries().last?.disposition, .remapped)
        XCTAssertFalse(session.snapshotEntries().last?.isSynthetic == true)
    }

    func testConcurrentRecordsStayWithinCap() {
        let session = InputCaptureSession(maxEntries: 50)
        let sink = InputCaptureDiagnosticSink()
        sink.update(enabled: true, session: session)

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            sink.record(
                control: .sideButton1,
                disposition: .consumed,
                detail: "concurrent-\(index)"
            )
        }

        XCTAssertEqual(session.snapshotEntries().count, 50)
        XCTAssertLessThanOrEqual(session.publicationEnqueueCount, 8)
    }
}
