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

    func testScalePassthroughScrollScalesAxis2InPlace() {
        var verticalLine = InputRemapperEngine.ScrollDeltaScaler()
        var verticalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalLine = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var nativeLine = InputRemapperEngine.ScrollDeltaScaler()
        var nativePoint = InputRemapperEngine.ScrollDeltaScaler()
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: .zero,
            axis2: .init(line: 3, point: 4, fixedPt: 1.5),
            verticalLineScaler: &verticalLine,
            verticalPointScaler: &verticalPoint,
            horizontalLineScaler: &horizontalLine,
            horizontalPointScaler: &horizontalPoint,
            nativeHorizontalLineScaler: &nativeLine,
            nativeHorizontalPointScaler: &nativePoint,
            multiplier: 2.0,
            invert: false,
            convertVerticalToHorizontal: false
        )
        XCTAssertEqual(scaled.axis1, .zero)
        XCTAssertEqual(scaled.axis2.line, 6)
        XCTAssertEqual(scaled.axis2.point, 8)
        XCTAssertEqual(scaled.axis2.fixedPt, 3.0, accuracy: 0.0001)
    }

    func testScalePassthroughScrollScalesDualAxisIndependently() {
        var verticalLine = InputRemapperEngine.ScrollDeltaScaler()
        var verticalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalLine = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var nativeLine = InputRemapperEngine.ScrollDeltaScaler()
        var nativePoint = InputRemapperEngine.ScrollDeltaScaler()
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: .init(line: 1, point: 2, fixedPt: 0.5),
            axis2: .init(line: 3, point: 4, fixedPt: 1.0),
            verticalLineScaler: &verticalLine,
            verticalPointScaler: &verticalPoint,
            horizontalLineScaler: &horizontalLine,
            horizontalPointScaler: &horizontalPoint,
            nativeHorizontalLineScaler: &nativeLine,
            nativeHorizontalPointScaler: &nativePoint,
            multiplier: 2.0,
            invert: false,
            convertVerticalToHorizontal: false
        )
        XCTAssertEqual(scaled.axis1.line, 2)
        XCTAssertEqual(scaled.axis1.point, 4)
        XCTAssertEqual(scaled.axis1.fixedPt, 1.0, accuracy: 0.0001)
        XCTAssertEqual(scaled.axis2.line, 6)
        XCTAssertEqual(scaled.axis2.point, 8)
        XCTAssertEqual(scaled.axis2.fixedPt, 2.0, accuracy: 0.0001)
    }

    func testScalePassthroughScrollShiftMergesConvertedAndNativeHorizontal() {
        var verticalLine = InputRemapperEngine.ScrollDeltaScaler()
        var verticalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalLine = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var nativeLine = InputRemapperEngine.ScrollDeltaScaler()
        var nativePoint = InputRemapperEngine.ScrollDeltaScaler()
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: .init(line: 1, point: 0, fixedPt: 0),
            axis2: .init(line: 3, point: 0, fixedPt: 0),
            verticalLineScaler: &verticalLine,
            verticalPointScaler: &verticalPoint,
            horizontalLineScaler: &horizontalLine,
            horizontalPointScaler: &horizontalPoint,
            nativeHorizontalLineScaler: &nativeLine,
            nativeHorizontalPointScaler: &nativePoint,
            multiplier: 2.0,
            invert: false,
            convertVerticalToHorizontal: true
        )
        XCTAssertEqual(scaled.axis1, .zero)
        XCTAssertEqual(scaled.axis2.line, 8)
    }

    func testScalePassthroughScrollInvertsNativeAxis2() {
        var verticalLine = InputRemapperEngine.ScrollDeltaScaler()
        var verticalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalLine = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var nativeLine = InputRemapperEngine.ScrollDeltaScaler()
        var nativePoint = InputRemapperEngine.ScrollDeltaScaler()
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: .zero,
            axis2: .init(line: 2, point: 4, fixedPt: 1.5),
            verticalLineScaler: &verticalLine,
            verticalPointScaler: &verticalPoint,
            horizontalLineScaler: &horizontalLine,
            horizontalPointScaler: &horizontalPoint,
            nativeHorizontalLineScaler: &nativeLine,
            nativeHorizontalPointScaler: &nativePoint,
            multiplier: 2.0,
            invert: true,
            convertVerticalToHorizontal: false
        )
        XCTAssertEqual(scaled.axis1, .zero)
        XCTAssertEqual(scaled.axis2.line, -4)
        XCTAssertEqual(scaled.axis2.point, -8)
        XCTAssertEqual(scaled.axis2.fixedPt, -3.0, accuracy: 0.0001)
    }

    func testNativeAxis2ResidualDoesNotTransferIntoShiftConvertedHorizontal() {
        var verticalLine = InputRemapperEngine.ScrollDeltaScaler()
        var verticalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalLine = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var nativeLine = InputRemapperEngine.ScrollDeltaScaler()
        var nativePoint = InputRemapperEngine.ScrollDeltaScaler()
        let nativeTick = InputRemapperEngine.ScrollAxisValues(line: 1, point: 0, fixedPt: 0)

        for _ in 0..<3 {
            XCTAssertEqual(
                InputRemapperEngine.scalePassthroughScroll(
                    axis1: .zero,
                    axis2: nativeTick,
                    verticalLineScaler: &verticalLine,
                    verticalPointScaler: &verticalPoint,
                    horizontalLineScaler: &horizontalLine,
                    horizontalPointScaler: &horizontalPoint,
                    nativeHorizontalLineScaler: &nativeLine,
                    nativeHorizontalPointScaler: &nativePoint,
                    multiplier: 0.25,
                    invert: false,
                    convertVerticalToHorizontal: false
                ).axis2.line,
                0
            )
        }

        let shifted = InputRemapperEngine.scalePassthroughScroll(
            axis1: nativeTick,
            axis2: .zero,
            verticalLineScaler: &verticalLine,
            verticalPointScaler: &verticalPoint,
            horizontalLineScaler: &horizontalLine,
            horizontalPointScaler: &horizontalPoint,
            nativeHorizontalLineScaler: &nativeLine,
            nativeHorizontalPointScaler: &nativePoint,
            multiplier: 0.25,
            invert: false,
            convertVerticalToHorizontal: true
        )
        XCTAssertEqual(shifted.axis1, .zero)
        XCTAssertEqual(
            shifted.axis2.line,
            0,
            "Shift-converted horizontal must not inherit native axis-2 residual"
        )

        XCTAssertEqual(
            InputRemapperEngine.scalePassthroughScroll(
                axis1: .zero,
                axis2: nativeTick,
                verticalLineScaler: &verticalLine,
                verticalPointScaler: &verticalPoint,
                horizontalLineScaler: &horizontalLine,
                horizontalPointScaler: &horizontalPoint,
                nativeHorizontalLineScaler: &nativeLine,
                nativeHorizontalPointScaler: &nativePoint,
                multiplier: 0.25,
                invert: false,
                convertVerticalToHorizontal: false
            ).axis2.line,
            1,
            "Native axis-2 residual must remain isolated after Shift conversion"
        )
    }

    func testScalePassthroughScrollAccumulatesPointDelta() {
        var lineScaler = InputRemapperEngine.ScrollDeltaScaler()
        var pointScaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 0, point: 1, fixedPt: 5.0)

        for _ in 0..<3 {
            let scaled = InputRemapperEngine.scalePassthroughScroll(
                axis1: axis1,
                lineScaler: &lineScaler,
                pointScaler: &pointScaler,
                multiplier: 0.25,
                invert: false,
                moveToHorizontalAxis: false
            )
            XCTAssertEqual(scaled.axis1.point, 0)
            XCTAssertEqual(scaled.axis1.fixedPt, 1.25, accuracy: 0.001)
        }
        let emitted = InputRemapperEngine.scalePassthroughScroll(
            axis1: axis1,
            lineScaler: &lineScaler,
            pointScaler: &pointScaler,
            multiplier: 0.25,
            invert: false,
            moveToHorizontalAxis: false
        )
        XCTAssertEqual(emitted.axis1.point, 1)
        XCTAssertEqual(emitted.axis1.fixedPt, 1.25, accuracy: 0.001)
    }

    func testScalePassthroughScrollInvertsAllAxes() {
        var lineScaler = InputRemapperEngine.ScrollDeltaScaler()
        var pointScaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 1, point: 4, fixedPt: 2.0)
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: axis1,
            lineScaler: &lineScaler,
            pointScaler: &pointScaler,
            multiplier: 2.0,
            invert: true,
            moveToHorizontalAxis: false
        )
        XCTAssertEqual(scaled.axis1.line, -2)
        XCTAssertEqual(scaled.axis1.point, -8)
        XCTAssertEqual(scaled.axis1.fixedPt, -4.0, accuracy: 0.001)
    }

    func testScalePassthroughScrollMovesAllFieldsToHorizontalAxis() {
        var lineScaler = InputRemapperEngine.ScrollDeltaScaler()
        var pointScaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 1, point: 6, fixedPt: 3.0)
        let scaled = InputRemapperEngine.scalePassthroughScroll(
            axis1: axis1,
            lineScaler: &lineScaler,
            pointScaler: &pointScaler,
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
        var lineScaler = InputRemapperEngine.ScrollDeltaScaler()
        var pointScaler = InputRemapperEngine.ScrollDeltaScaler()
        let axis1 = InputRemapperEngine.ScrollAxisValues(line: 1, point: 0, fixedPt: 0)
        for _ in 0..<3 {
            XCTAssertEqual(
                InputRemapperEngine.scalePassthroughScroll(
                    axis1: axis1,
                    lineScaler: &lineScaler,
                    pointScaler: &pointScaler,
                    multiplier: 0.25,
                    invert: false,
                    moveToHorizontalAxis: false
                ).axis1.line,
                0
            )
        }
        XCTAssertEqual(
            InputRemapperEngine.scalePassthroughScroll(
                axis1: axis1,
                lineScaler: &lineScaler,
                pointScaler: &pointScaler,
                multiplier: 0.25,
                invert: false,
                moveToHorizontalAxis: false
            ).axis1.line,
            1
        )
    }

    func testScrollScalerAccumulatesNegativeFractionalDeltas() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        XCTAssertEqual(scaler.scale(rawDelta: -1, multiplier: 0.25), 0)
        XCTAssertEqual(scaler.scale(rawDelta: -1, multiplier: 0.25), 0)
        XCTAssertEqual(scaler.scale(rawDelta: -1, multiplier: 0.25), 0)
        XCTAssertEqual(scaler.scale(rawDelta: -1, multiplier: 0.25), -1)
    }

    func testScrollScalerZeroDeltaLeavesAccumulatorUnchanged() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        XCTAssertEqual(scaler.scale(rawDelta: 1, multiplier: 0.5), 0)
        XCTAssertEqual(scaler.scale(rawDelta: 0, multiplier: 0.5), 0)
        XCTAssertEqual(scaler.scale(rawDelta: 1, multiplier: 0.5), 1)
    }

    func testScrollScalerResetsResidualOnDirectionReversal() {
        var scaler = InputRemapperEngine.ScrollDeltaScaler()
        XCTAssertEqual(scaler.scale(rawDelta: 1, multiplier: 0.75), 0) // residual +0.75
        // Opposite direction must not be delayed by the prior residual.
        XCTAssertEqual(scaler.scale(rawDelta: -1, multiplier: 0.75), 0) // residual -0.75
        XCTAssertEqual(scaler.scale(rawDelta: -1, multiplier: 0.75), -1)
    }

    func testVerticalResidualDoesNotTransferToHorizontalOutput() {
        var verticalLine = InputRemapperEngine.ScrollDeltaScaler()
        var verticalPoint = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalLine = InputRemapperEngine.ScrollDeltaScaler()
        var horizontalPoint = InputRemapperEngine.ScrollDeltaScaler()
        let tick = InputRemapperEngine.ScrollAxisValues(line: 1, point: 0, fixedPt: 0)

        for _ in 0..<3 {
            XCTAssertEqual(
                InputRemapperEngine.scalePassthroughScroll(
                    axis1: tick,
                    lineScaler: &verticalLine,
                    pointScaler: &verticalPoint,
                    multiplier: 0.25,
                    invert: false,
                    moveToHorizontalAxis: false
                ).axis1.line,
                0
            )
        }

        let shifted = InputRemapperEngine.scalePassthroughScroll(
            axis1: tick,
            lineScaler: &horizontalLine,
            pointScaler: &horizontalPoint,
            multiplier: 0.25,
            invert: false,
            moveToHorizontalAxis: true
        )
        XCTAssertEqual(shifted.axis1, .zero)
        XCTAssertEqual(shifted.axis2.line, 0, "Horizontal must not inherit vertical residual")

        XCTAssertEqual(
            InputRemapperEngine.scalePassthroughScroll(
                axis1: tick,
                lineScaler: &verticalLine,
                pointScaler: &verticalPoint,
                multiplier: 0.25,
                invert: false,
                moveToHorizontalAxis: false
            ).axis1.line,
            1
        )
    }

    func testPrimaryScrollDeltaPrefersLineThenPointThenFixedPt() {
        XCTAssertEqual(
            InputRemapperEngine.primaryScrollDelta(
                for: .init(line: 2, point: -9, fixedPt: -3)
            ),
            2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            InputRemapperEngine.primaryScrollDelta(
                for: .init(line: 0, point: -3, fixedPt: 8)
            ),
            -3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            InputRemapperEngine.primaryScrollDelta(
                for: .init(line: 0, point: 0, fixedPt: 1.25)
            ),
            1.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            InputRemapperEngine.primaryScrollDelta(
                for: .init(line: 0, point: 0, fixedPt: -0.5)
            ),
            -0.5,
            accuracy: 0.0001
        )
    }

    func testFixedPointOnlyEventsSelectWheelDirectionFromSign() {
        XCTAssertGreaterThan(
            InputRemapperEngine.primaryScrollDelta(for: .init(line: 0, point: 0, fixedPt: 0.75)),
            0
        )
        XCTAssertLessThan(
            InputRemapperEngine.primaryScrollDelta(for: .init(line: 0, point: 0, fixedPt: -0.75)),
            0
        )
    }

    func testNonFiniteMultipliersAreRejected() {
        XCTAssertThrowsError(try ProfileValidator.validateWheelSpeedMultiplier(.nan)) { error in
            XCTAssertEqual(error as? RazerValidationError, .invalidWheelSpeedMultiplier)
        }
        XCTAssertThrowsError(try ProfileValidator.validateWheelSpeedMultiplier(.infinity))
        XCTAssertThrowsError(try ProfileValidator.validateWheelSpeedMultiplier(-.infinity))
        XCTAssertThrowsError(try ProfileValidator.validateWheelSpeedMultiplier(0))
        XCTAssertThrowsError(try ProfileValidator.validateWheelSpeedMultiplier(-1))
        XCTAssertThrowsError(try ProfileValidator.validateWheelSpeedMultiplier(3.01))
        XCTAssertNoThrow(try ProfileValidator.validateWheelSpeedMultiplier(0.25))
        XCTAssertNoThrow(try ProfileValidator.validateWheelSpeedMultiplier(1))
        XCTAssertNoThrow(try ProfileValidator.validateWheelSpeedMultiplier(3))
    }

    func testSanitizedMultiplierMapsNonFiniteToDefault() {
        XCTAssertEqual(SoftwareWheelSettings.sanitizedSpeedMultiplier(.nan), 1.0)
        XCTAssertEqual(SoftwareWheelSettings.sanitizedSpeedMultiplier(.infinity), 1.0)
        XCTAssertEqual(SoftwareWheelSettings.sanitizedSpeedMultiplier(0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(SoftwareWheelSettings.sanitizedSpeedMultiplier(10), 3.0, accuracy: 0.0001)
        XCTAssertEqual(SoftwareWheelSettings.sanitizedSpeedMultiplier(1.5), 1.5, accuracy: 0.0001)
    }

    func testSoftwareWheelSettingsDecodeAndInitSanitizeMultipliers() throws {
        let settings = SoftwareWheelSettings(verticalSpeedMultiplier: .nan)
        XCTAssertEqual(settings.verticalSpeedMultiplier, 1.0)

        let oversized = Data(
            #"{"scrollDirection":"normal","verticalSpeedMultiplier":99,"horizontalScrollModifier":"shift"}"#.utf8
        )
        let decodedOversized = try JSONDecoder().decode(SoftwareWheelSettings.self, from: oversized)
        XCTAssertEqual(decodedOversized.verticalSpeedMultiplier, 3.0)

        let nullMultiplier = Data(
            #"{"scrollDirection":"normal","verticalSpeedMultiplier":null,"horizontalScrollModifier":"shift"}"#.utf8
        )
        let decodedNull = try JSONDecoder().decode(SoftwareWheelSettings.self, from: nullMultiplier)
        XCTAssertEqual(decodedNull.verticalSpeedMultiplier, 1.0)
    }

    // MARK: - ScrollActionThrottle (Task 9)

    func testScrollActionThrottleBurstWithinWindowFiresOnce() {
        var throttle = InputRemapperEngine.ScrollActionThrottle()
        var fireCount = 0
        // 10 ticks inside 20ms at 2ms spacing.
        for index in 0..<10 {
            let time = Double(index) * 0.002
            if throttle.shouldFire(direction: 1, at: time) {
                fireCount += 1
            }
        }
        XCTAssertEqual(fireCount, 1)
    }

    func testScrollActionThrottleExactThresholdFires() {
        var throttle = InputRemapperEngine.ScrollActionThrottle(minimumInterval: 0.060)
        XCTAssertTrue(throttle.shouldFire(direction: 1, at: 1.000))
        XCTAssertFalse(throttle.shouldFire(direction: 1, at: 1.059))
        XCTAssertTrue(throttle.shouldFire(direction: 1, at: 1.060))
        XCTAssertTrue(throttle.shouldFire(direction: 1, at: 1.120))
    }

    func testScrollActionThrottleDirectionChangeFiresImmediatelyAndResets() {
        var throttle = InputRemapperEngine.ScrollActionThrottle(minimumInterval: 0.060)
        XCTAssertTrue(throttle.shouldFire(direction: 1, at: 2.000))
        XCTAssertFalse(throttle.shouldFire(direction: 1, at: 2.010))
        XCTAssertTrue(throttle.shouldFire(direction: -1, at: 2.011))
        XCTAssertFalse(throttle.shouldFire(direction: -1, at: 2.020))
        XCTAssertTrue(throttle.shouldFire(direction: -1, at: 2.071))
    }

    func testScrollActionThrottleResetClearsWindow() {
        var throttle = InputRemapperEngine.ScrollActionThrottle(minimumInterval: 0.060)
        XCTAssertTrue(throttle.shouldFire(direction: 1, at: 3.000))
        throttle.reset()
        XCTAssertTrue(throttle.shouldFire(direction: 1, at: 3.001))
    }
}
