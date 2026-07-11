import XCTest
@testable import RazerCore

final class InputCaptureSessionTests: XCTestCase {
    func testSnapshotStartsEmpty() {
        let session = InputCaptureSession()
        XCTAssertTrue(session.snapshotEntries().isEmpty)
    }

    func testClearNotifiesCallbackWithEmptySnapshot() {
        let session = InputCaptureSession(maxEntries: 10)
        session.append(
            .init(eventType: "leftMouseDown", control: .leftClick, disposition: .observed, summary: "seed")
        )
        XCTAssertEqual(session.snapshotEntries().count, 1)

        let expectation = expectation(description: "entries cleared")
        session.onEntriesChanged = { entries in
            XCTAssertTrue(entries.isEmpty)
            expectation.fulfill()
        }
        session.clear()
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(session.snapshotEntries().isEmpty)
    }

    func testCapEvictionDropsOldestEntries() {
        let session = InputCaptureSession(maxEntries: 3)
        for index in 0..<5 {
            session.append(
                .init(
                    eventType: "scrollWheel",
                    disposition: .observed,
                    summary: "event-\(index)"
                )
            )
        }
        let entries = session.snapshotEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.summary), ["event-2", "event-3", "event-4"])
    }

    func testFastScrollBurstStaysWithinCap() {
        let session = InputCaptureSession(maxEntries: 50)
        for index in 0..<500 {
            session.append(
                .init(
                    eventType: "scrollWheel",
                    wheelAxes: .init(axis1Line: Int64(index % 3), axis1Point: 1),
                    control: .wheelUp,
                    disposition: .observed,
                    summary: "scroll-\(index)"
                )
            )
        }
        XCTAssertEqual(session.snapshotEntries().count, 50)
        XCTAssertEqual(session.snapshotEntries().last?.summary, "scroll-499")
    }

    func testEntriesChangedPublishedOnMainThread() {
        let session = InputCaptureSession(maxEntries: 5)
        let expectation = expectation(description: "main-thread callback")
        session.onEntriesChanged = { _ in
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            session.append(
                .init(eventType: "rightMouseDown", control: .rightClick, disposition: .observed, summary: "click")
            )
        }
        wait(for: [expectation], timeout: 1)
    }

    func testSyntheticMarkerLabeledInDisposition() {
        let session = InputCaptureSession(maxEntries: 5)
        session.append(
            .init(
                eventType: "leftMouseDown",
                control: .leftClick,
                isSynthetic: true,
                disposition: .synthetic,
                summary: "leftMouseDown | synthetic | Left Click | marker"
            )
        )
        let entry = try! XCTUnwrap(session.snapshotEntries().first)
        XCTAssertTrue(entry.isSynthetic)
        XCTAssertEqual(entry.disposition, .synthetic)
        XCTAssertTrue(entry.summary.contains("synthetic"))
        XCTAssertTrue(entry.summary.contains("marker"))
    }

    func testRemapObservationRecordsDispositionWithoutKeyboardPayload() {
        let session = InputCaptureSession(maxEntries: 5)
        session.recordRemapObservation(
            control: .sideButton1,
            disposition: .consumed,
            detail: "one-shot"
        )
        let entry = try! XCTUnwrap(session.snapshotEntries().first)
        XCTAssertEqual(entry.eventType, "remap")
        XCTAssertEqual(entry.disposition, .consumed)
        XCTAssertEqual(entry.control, .sideButton1)
        XCTAssertFalse(entry.summary.lowercased().contains("character"))
        XCTAssertFalse(entry.summary.contains("keyCode"))
    }

    func testClearReleasesRetainedEntriesImmediately() {
        let session = InputCaptureSession(maxEntries: 100)
        for index in 0..<100 {
            session.append(.init(eventType: "leftMouseDown", disposition: .observed, summary: "\(index)"))
        }
        session.clear()
        XCTAssertTrue(session.snapshotEntries().isEmpty)
        session.append(.init(eventType: "rightMouseDown", disposition: .observed, summary: "after-clear"))
        XCTAssertEqual(session.snapshotEntries().map(\.summary), ["after-clear"])
    }
}
