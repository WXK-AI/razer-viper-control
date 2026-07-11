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

    func testFastScrollBurstCoalescesObserverPublication() {
        let session = InputCaptureSession(maxEntries: 50)
        let lock = NSLock()
        var callbackCount = 0
        var lastCount = -1
        session.onEntriesChanged = { entries in
            XCTAssertTrue(Thread.isMainThread)
            lock.lock()
            callbackCount += 1
            lastCount = entries.count
            lock.unlock()
        }

        let burstDone = expectation(description: "burst finished")
        DispatchQueue.global(qos: .userInitiated).async {
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
            burstDone.fulfill()
        }
        wait(for: [burstDone], timeout: 2)

        let settled = expectation(description: "coalesced publish delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1)

        lock.lock()
        let observedCallbacks = callbackCount
        let observedLastCount = lastCount
        lock.unlock()

        XCTAssertEqual(session.snapshotEntries().count, 50)
        XCTAssertEqual(observedLastCount, 50)
        // Sliding debounce must collapse a tight burst far below one callback per event.
        XCTAssertLessThan(observedCallbacks, 10, "expected coalesced publishes, got \(observedCallbacks)")
        XCTAssertGreaterThanOrEqual(observedCallbacks, 1)
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
        XCTAssertFalse(entry.isSynthetic)
        XCTAssertFalse(entry.summary.lowercased().contains("character"))
        XCTAssertFalse(entry.summary.contains("keyCode"))
    }

    func testRemappedObservationIsNotLabeledSynthetic() {
        let session = InputCaptureSession(maxEntries: 5)
        session.recordRemapObservation(
            control: .rightClick,
            disposition: .remapped,
            detail: "to leftClick"
        )
        let entry = try! XCTUnwrap(session.snapshotEntries().first)
        XCTAssertEqual(entry.disposition, .remapped)
        XCTAssertFalse(entry.isSynthetic)
        XCTAssertFalse(entry.summary.contains("synthetic"))
        XCTAssertTrue(entry.summary.contains("remapped"))
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

    func testClearWinsOverQueuedPublication() {
        let session = InputCaptureSession(maxEntries: 50)
        let lock = NSLock()
        var receivedSnapshots: [[InputCaptureSession.Entry]] = []
        session.onEntriesChanged = { entries in
            lock.lock()
            receivedSnapshots.append(entries)
            lock.unlock()
        }

        let burstDone = expectation(description: "seed burst")
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<100 {
                session.append(
                    .init(eventType: "scrollWheel", disposition: .observed, summary: "pre-\(index)")
                )
            }
            burstDone.fulfill()
        }
        wait(for: [burstDone], timeout: 2)

        // Clear while a coalesced publish may still be outstanding.
        session.clear()
        XCTAssertTrue(session.snapshotEntries().isEmpty)

        let settled = expectation(description: "publications drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1)

        lock.lock()
        let snapshots = receivedSnapshots
        lock.unlock()

        XCTAssertTrue(session.snapshotEntries().isEmpty)
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(
            snapshots.last?.isEmpty == true,
            "queued publishes must re-snapshot; last delivery should be empty after clear"
        )
        if let firstEmptyIndex = snapshots.firstIndex(where: \.isEmpty) {
            let afterClear = snapshots[(firstEmptyIndex + 1)...]
            XCTAssertFalse(
                afterClear.contains { !$0.isEmpty },
                "stale pre-clear snapshots must not repopulate after clear"
            )
        }
    }
}
