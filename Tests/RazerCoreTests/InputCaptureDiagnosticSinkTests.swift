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

    func testDisableAndClearDropsInFlightRecords() {
        let session = InputCaptureSession(maxEntries: 500)
        let sink = InputCaptureDiagnosticSink()
        sink.update(enabled: true, session: session)

        let writers = DispatchGroup()
        for _ in 0..<8 {
            writers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for index in 0..<200 {
                    sink.record(
                        control: .wheelUp,
                        disposition: .remapped,
                        detail: "race-\(index)"
                    )
                }
                writers.leave()
            }
        }

        // Disable+clear while writers are still appending.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.001) {
            sink.disableAndClear()
        }

        XCTAssertEqual(writers.wait(timeout: .now() + 2), .success)

        // Any record that observed `enabled` must finish before disableAndClear
        // returns; afterward the buffer stays empty and further records no-op.
        XCTAssertTrue(session.snapshotEntries().isEmpty)
        sink.record(control: .wheelUp, disposition: .remapped, detail: "after-disable")
        XCTAssertTrue(session.snapshotEntries().isEmpty)
    }

    func testClearSerializesWithConcurrentRecords() {
        let session = InputCaptureSession(maxEntries: 500)
        let sink = InputCaptureDiagnosticSink()
        sink.update(enabled: true, session: session)

        let writers = DispatchGroup()
        for _ in 0..<4 {
            writers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for index in 0..<150 {
                    sink.record(
                        control: .leftClick,
                        disposition: .consumed,
                        detail: "pre-clear-\(index)"
                    )
                }
                writers.leave()
            }
        }

        for _ in 0..<20 {
            sink.clear()
        }

        XCTAssertEqual(writers.wait(timeout: .now() + 2), .success)
        sink.clear()
        XCTAssertTrue(
            session.snapshotEntries().isEmpty,
            "final clear under the sink lock must drop any record that started before it"
        )
    }
}
