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
            .consume
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

    func testManyToOneTargetsTrackIndependentHolds() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([
            .sideButton1: .mouseButton(.left),
            .sideButton2: .mouseButton(.left)
        ])

        XCTAssertEqual(
            session.handle(control: .sideButton1, kind: .down, mappings: map),
            .postMouse(.left, isDown: true)
        )
        XCTAssertEqual(
            session.handle(control: .sideButton2, kind: .down, mappings: map),
            .postMouse(.left, isDown: true)
        )
        XCTAssertEqual(
            session.handle(control: .sideButton1, kind: .up, mappings: map),
            .postMouse(.left, isDown: false)
        )
        XCTAssertTrue(session.isHolding(.sideButton2))
        XCTAssertEqual(
            session.handle(control: .sideButton2, kind: .up, mappings: map),
            .postMouse(.left, isDown: false)
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

    func testSnapshotHeldMouseTargetsForRelease() {
        var session = InputRemapperEngine.ButtonRemapSession()
        let map = mappings([
            .leftClick: .mouseButton(.right),
            .sideButton1: .mouseButton(.left)
        ])
        _ = session.handle(control: .leftClick, kind: .down, mappings: map)
        _ = session.handle(control: .sideButton1, kind: .down, mappings: map)
        let targets = session.snapshotHeldMouseTargets()
        XCTAssertEqual(Set(targets), Set([MouseButtonTarget.right, .left]))
        session.clearAllHolds()
        XCTAssertTrue(session.snapshotHeldMouseTargets().isEmpty)
    }
}
