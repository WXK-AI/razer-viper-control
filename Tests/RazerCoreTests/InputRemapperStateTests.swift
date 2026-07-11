import XCTest
@testable import RazerCore

final class InputRemapperStateTests: XCTestCase {
    private func mappings(_ pairs: [PhysicalControl: ButtonAction]) -> [PhysicalControl: ButtonAction] {
        var result = PhysicalControl.defaultButtonMappings()
        for (control, action) in pairs {
            result[control] = action
        }
        return result
    }

    func testLeftRightSwapDownDragUpUsesStoredTarget() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([
            .leftClick: .mouseButton(.right),
            .rightClick: .mouseButton(.left)
        ])

        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .down, mappings: map),
            .postMouse(.right, isDown: true)
        )
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .drag, mappings: map),
            .postMouseDrag(.right)
        )
        // Mapping flip mid-hold must not change the stored right-button release.
        let flipped = mappings([
            .leftClick: .mouseButton(.left),
            .rightClick: .mouseButton(.right)
        ])
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .up, mappings: flipped),
            .postMouse(.right, isDown: false)
        )
        XCTAssertFalse(session.isHolding(.leftClick))
    }

    func testDuplicateSourceDownDoesNotLeakTargetOwnership() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([.leftClick: .mouseButton(.right)])

        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .down, mappings: map),
            .postMouse(.right, isDown: true)
        )
        // A second down for the same source must not inflate the target refcount.
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .down, mappings: map),
            .consume
        )
        XCTAssertEqual(session.snapshotHeldMouseTargets(), [.right])
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .up, mappings: map),
            .postMouse(.right, isDown: false)
        )
        XCTAssertFalse(session.isHolding(.leftClick))
        XCTAssertTrue(session.snapshotHeldMouseTargets().isEmpty)
    }

    func testManyToOneTargetsOnlyReleaseOnLastOwnerUp() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([
            .sideButton1: .mouseButton(.left),
            .sideButton2: .mouseButton(.left)
        ])

        XCTAssertEqual(
            session.handle(control: .sideButton1, kind: .down, mappings: map),
            .postMouse(.left, isDown: true)
        )
        // Second owner of the same target must not post another down.
        XCTAssertEqual(
            session.handle(control: .sideButton2, kind: .down, mappings: map),
            .consume
        )
        // First release keeps synthetic left held for the remaining owner.
        XCTAssertEqual(
            session.handle(control: .sideButton1, kind: .up, mappings: map),
            .consume
        )
        XCTAssertTrue(session.isHolding(.sideButton2))
        XCTAssertEqual(session.snapshotHeldMouseTargets(), [.left])
        XCTAssertEqual(
            session.handle(control: .sideButton2, kind: .up, mappings: map),
            .postMouse(.left, isDown: false)
        )
        XCTAssertTrue(session.snapshotHeldMouseTargets().isEmpty)
    }

    func testMouseDragReplacementIsEmittedForRemappedHold() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([.leftClick: .mouseButton(.right)])
        _ = session.handle(control: .leftClick, kind: .down, mappings: map)
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .drag, mappings: map),
            .postMouseDrag(.right)
        )
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .drag, mappings: map),
            .postMouseDrag(.right)
        )
    }

    func testDisabledDownConsumesMatchingUpEvenAfterMappingChange() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let disabled = mappings([.dpiButton: .disabled])
        XCTAssertEqual(
            session.handle(control: .dpiButton, kind: .down, mappings: disabled),
            .consume
        )
        XCTAssertEqual(
            session.handle(control: .dpiButton, kind: .drag, mappings: disabled),
            .consume
        )
        let enabled = mappings([.dpiButton: .passthrough])
        XCTAssertEqual(
            session.handle(control: .dpiButton, kind: .up, mappings: enabled),
            .consume
        )
    }

    func testOneShotFiresOnDownAndConsumesUp() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let action = ButtonAction.nextDPIStage
        let map = mappings([.sideButton1: action])
        XCTAssertEqual(
            session.handle(control: .sideButton1, kind: .down, mappings: map),
            .fireOneShot(action)
        )
        XCTAssertEqual(
            session.handle(control: .sideButton1, kind: .up, mappings: map),
            .consume
        )
    }

    func testUnmatchedUpPassesThrough() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([:])
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .up, mappings: map),
            .passThrough
        )
    }

    func testPassthroughHoldStillPassesDragAndUp() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([.leftClick: .passthrough])
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .down, mappings: map),
            .passThrough
        )
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .drag, mappings: map),
            .passThrough
        )
        XCTAssertEqual(
            session.handle(control: .leftClick, kind: .up, mappings: map),
            .passThrough
        )
    }

    func testSnapshotHeldMouseTargetsIsUniqueForRecovery() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([
            .leftClick: .mouseButton(.right),
            .sideButton1: .mouseButton(.left),
            .sideButton2: .mouseButton(.left)
        ])
        _ = session.handle(control: .leftClick, kind: .down, mappings: map)
        _ = session.handle(control: .sideButton1, kind: .down, mappings: map)
        _ = session.handle(control: .sideButton2, kind: .down, mappings: map)
        let targets = Set(session.snapshotHeldMouseTargets())
        XCTAssertEqual(targets, Set([MouseButtonTarget.right, .left]))
        session.clearAllHolds()
        XCTAssertTrue(session.snapshotHeldMouseTargets().isEmpty)
    }

    func testReleaseAllHeldOutputsClearsStateIdempotently() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([
            .leftClick: .mouseButton(.right),
            .sideButton1: .mouseButton(.left),
            .sideButton2: .mouseButton(.left)
        ])
        _ = session.handle(control: .leftClick, kind: .down, mappings: map)
        _ = session.handle(control: .sideButton1, kind: .down, mappings: map)
        _ = session.handle(control: .sideButton2, kind: .down, mappings: map)

        XCTAssertEqual(Set(session.releaseAllHeldOutputs()), Set([MouseButtonTarget.right, .left]))
        XCTAssertTrue(session.snapshotHeldMouseTargets().isEmpty)
        XCTAssertTrue(session.releaseAllHeldOutputs().isEmpty)
    }
}
