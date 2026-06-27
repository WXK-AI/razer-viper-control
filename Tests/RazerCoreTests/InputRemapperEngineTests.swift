import XCTest
@testable import RazerCore

final class InputRemapperEngineTests: XCTestCase {
    func testSyntheticMarkerIsIgnored() {
        XCTAssertTrue(InputRemapperEngine.shouldIgnoreSynthetic(sourceUserData: InputRemapperEngine.syntheticMarker))
        XCTAssertFalse(InputRemapperEngine.shouldIgnoreSynthetic(sourceUserData: 0))
    }

    func testLeftRightSwapMapsDownAndUpSeparately() {
        let leftDown = InputRemapperEngine.buttonOutcome(action: .mouseButton(.right), isDown: true)
        let leftUp = InputRemapperEngine.buttonOutcome(action: .mouseButton(.right), isDown: false)
        let rightDown = InputRemapperEngine.buttonOutcome(action: .mouseButton(.left), isDown: true)
        let rightUp = InputRemapperEngine.buttonOutcome(action: .mouseButton(.left), isDown: false)

        XCTAssertEqual(leftDown, .postMouse(.right, isDown: true))
        XCTAssertEqual(leftUp, .postMouse(.right, isDown: false))
        XCTAssertEqual(rightDown, .postMouse(.left, isDown: true))
        XCTAssertEqual(rightUp, .postMouse(.left, isDown: false))
    }

    func testOneShotActionsFireOnlyOnDown() {
        let shortcut = ButtonAction.keyboardShortcut(KeyboardShortcut(keyCode: 0, modifierFlags: 0x0010_0000))
        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: shortcut, isDown: true), .fireOneShot(shortcut))
        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: shortcut, isDown: false), .consume)

        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: .nextDPIStage, isDown: true), .fireOneShot(.nextDPIStage))
        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: .nextDPIStage, isDown: false), .consume)

        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: .openURL("https://example.com"), isDown: true), .fireOneShot(.openURL("https://example.com")))
        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: .openURL("https://example.com"), isDown: false), .consume)
    }

    func testPassthroughAndDisabled() {
        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: .passthrough, isDown: true), .passThrough)
        XCTAssertEqual(InputRemapperEngine.buttonOutcome(action: .disabled, isDown: true), .consume)
    }

    func testEmergencyPauseMatchesWithExtraHarmlessFlags() {
        let shortcut = KeyboardShortcut.emergencyPause
        XCTAssertTrue(InputRemapperEngine.matchesShortcut(
            shortcut,
            keyCode: shortcut.keyCode,
            modifierFlags: shortcut.modifierFlags
        ))
        XCTAssertTrue(InputRemapperEngine.matchesShortcut(
            shortcut,
            keyCode: shortcut.keyCode,
            modifierFlags: shortcut.modifierFlags | 0x0001_0000
        ))
        XCTAssertFalse(InputRemapperEngine.matchesShortcut(
            shortcut,
            keyCode: shortcut.keyCode,
            modifierFlags: shortcut.modifierFlags & ~0x0010_0000
        ))
    }

    func testScrollScalerAccumulatesFractionalDeltas() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        XCTAssertEqual(scaler.scale(rawDelta: 1, multiplier: 0.25), 0)
        XCTAssertEqual(scaler.scale(rawDelta: 1, multiplier: 0.25), 0)
        XCTAssertEqual(scaler.scale(rawDelta: 1, multiplier: 0.25), 0)
        XCTAssertEqual(scaler.scale(rawDelta: 1, multiplier: 0.25), 1)

        var fastScaler = InputRemapperEngine.ScrollDeltaScaler()
        XCTAssertEqual(fastScaler.scale(rawDelta: 1, multiplier: 2.0), 2)
    }

    func testTruncationWouldZeroSlowScroll() {
        XCTAssertEqual(InputRemapperEngine.scaledScrollDelta(rawDelta: 1, multiplier: 0.5), 0)
        XCTAssertEqual(InputRemapperEngine.scaledScrollDelta(rawDelta: 1, multiplier: 0.99), 0)
    }

    func testWheelClickAliasResolvesMiddleMapping() {
        let mappings: [PhysicalControl: ButtonAction] = [
            .middleClick: .mouseButton(.right)
        ]
        XCTAssertEqual(
            InputRemapperEngine.resolvedButtonAction(for: .wheelClick, in: mappings),
            .mouseButton(.right)
        )
        XCTAssertEqual(
            InputRemapperEngine.resolvedButtonAction(for: .middleClick, in: mappings),
            .mouseButton(.right)
        )
    }

    func testWheelClickAliasWithExplicitDefaultPassthrough() {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.middleClick] = .mouseButton(.right)
        XCTAssertEqual(
            InputRemapperEngine.resolvedButtonAction(for: .wheelClick, in: mappings),
            .mouseButton(.right)
        )

        mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelClick] = .mouseButton(.left)
        XCTAssertEqual(
            InputRemapperEngine.resolvedButtonAction(for: .middleClick, in: mappings),
            .mouseButton(.left)
        )
    }

    func testAssignableControlsExcludesMiddleClick() {
        XCTAssertFalse(PhysicalControl.assignableControls.contains(.middleClick))
        XCTAssertTrue(PhysicalControl.assignableControls.contains(.wheelClick))
        XCTAssertEqual(
            PhysicalControl.assignableControls.count,
            PhysicalControl.allCases.count - 1
        )
    }

    func testScalePassthroughScrollScalesPointDeltaImmediately() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 0, point: 10, fixedPt: 5.0)
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: axis1,
            lineScaler: &scaler,
            multiplier: 0.5,
            invert: false,
            moveToHorizontalAxis: false
        )
        XCTAssertEqual(scaled.axis1.line, 0)
        XCTAssertEqual(scaled.axis1.point, 5)
        XCTAssertEqual(scaled.axis1.fixedPt, 2.5, accuracy: 0.001)
    }

    func testScalePassthroughScrollInvertsAllAxes() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 1, point: 4, fixedPt: 2.0)
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: axis1,
            lineScaler: &scaler,
            multiplier: 2.0,
            invert: true,
            moveToHorizontalAxis: false
        )
        XCTAssertEqual(scaled.axis1.line, -2)
        XCTAssertEqual(scaled.axis1.point, -8)
        XCTAssertEqual(scaled.axis1.fixedPt, -4.0, accuracy: 0.001)
    }

    func testScalePassthroughScrollMovesAllFieldsToHorizontalAxis() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 1, point: 6, fixedPt: 3.0)
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: axis1,
            lineScaler: &scaler,
            multiplier: 1.0,
            invert: false,
            moveToHorizontalAxis: true
        )
        XCTAssertEqual(scaled.axis1, .zero)
        XCTAssertEqual(scaled.axis2.line, 1)
        XCTAssertEqual(scaled.axis2.point, 6)
        XCTAssertEqual(scaled.axis2.fixedPt, 3.0, accuracy: 0.001)
    }

    func testLineScalerStillAccumulatesSubUnityMultipliers() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 1, point: 0, fixedPt: 0)
        for _ in 0..<3 {
            XCTAssertEqual(
                InputRemapperEngine.scalePassthroughScroll(
                    axis1: axis1, lineScaler: &scaler, multiplier: 0.25, invert: false, moveToHorizontalAxis: false
                ).axis1.line,
                0
            )
        }
        XCTAssertEqual(
            InputRemapperEngine.scalePassthroughScroll(
                axis1: axis1, lineScaler: &scaler, multiplier: 0.25, invert: false, moveToHorizontalAxis: false
            ).axis1.line,
            1
        )
    }
}
