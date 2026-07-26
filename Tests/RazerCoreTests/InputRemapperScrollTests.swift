import CoreGraphics
import XCTest
@testable import RazerCore

final class InputRemapperScrollTests: XCTestCase {
    private func makeProfile(
        multiplier: Double = 2.0,
        invert: Bool = false,
        shiftHorizontal: Bool = true,
        mappings: [PhysicalControl: ButtonAction] = PhysicalControl.defaultButtonMappings(),
        wheelUpAction: ButtonAction? = nil,
        wheelDownAction: ButtonAction? = nil
    ) -> MouseProfile {
        MouseProfile(
            name: "Scroll Test",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000,
            buttonMappings: mappings,
            wheelSettings: WheelSettings(
                software: SoftwareWheelSettings(
                    scrollDirection: invert ? .inverted : .normal,
                    verticalSpeedMultiplier: multiplier,
                    horizontalScrollModifier: shiftHorizontal ? .shift : .none,
                    wheelUpAction: wheelUpAction,
                    wheelDownAction: wheelDownAction
                )
            ),
            remapperEnabled: true
        )
    }

    private func makeScrollEvent(
        axis1Line: Int32 = 0,
        axis2Line: Int32 = 0,
        axis1Point: Int64 = 0,
        axis2Point: Int64 = 0,
        axis1Fixed: Double = 0,
        axis2Fixed: Double = 0,
        shift: Bool = false
    ) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: axis1Line,
            wheel2: axis2Line,
            wheel3: 0
        ) else {
            return nil
        }
        if axis1Point != 0 {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: axis1Point)
        }
        if axis2Point != 0 {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: axis2Point)
        }
        if axis1Fixed != 0 {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: axis1Fixed)
        }
        if axis2Fixed != 0 {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: axis2Fixed)
        }
        if shift {
            event.flags.insert(.maskShift)
        }
        return event
    }

    private func requireScrollEvent(
        axis1Line: Int32 = 0,
        axis2Line: Int32 = 0,
        axis1Point: Int64 = 0,
        axis2Point: Int64 = 0,
        axis1Fixed: Double = 0,
        axis2Fixed: Double = 0,
        shift: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGEvent {
        guard let event = makeScrollEvent(
            axis1Line: axis1Line,
            axis2Line: axis2Line,
            axis1Point: axis1Point,
            axis2Point: axis2Point,
            axis1Fixed: axis1Fixed,
            axis2Fixed: axis2Fixed,
            shift: shift
        ) else {
            throw XCTSkip("CGEvent scroll construction unavailable in this environment")
        }
        return event
    }

    private func axisValues(_ event: CGEvent) -> (
        a1Line: Int64, a2Line: Int64,
        a1Point: Int64, a2Point: Int64,
        a1Fixed: Double, a2Fixed: Double
    ) {
        (
            event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
    }

    func testAxis2OnlyLineDeltaIsScaledInPlace() throws {
        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(multiplier: 2.0))
        let event = try requireScrollEvent(axis2Line: 3)

        let result = processScroll(remapper, event)
        XCTAssertNotNil(result)
        let out = try XCTUnwrap(result)
        let values = axisValues(out)
        XCTAssertEqual(values.a1Line, 0)
        XCTAssertEqual(values.a2Line, 6)
    }

    func testAxis2OnlyPointAndFixedAreScaledInPlace() throws {
        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(multiplier: 2.0))
        let event = try requireScrollEvent(axis2Point: 4, axis2Fixed: 1.5)

        let result = processScroll(remapper, event)
        let out = try XCTUnwrap(result)
        let values = axisValues(out)
        XCTAssertEqual(values.a1Point, 0)
        XCTAssertEqual(values.a2Point, 8)
        XCTAssertEqual(values.a1Fixed, 0, accuracy: 0.0001)
        XCTAssertEqual(values.a2Fixed, 3.0, accuracy: 0.0001)
    }

    func testDualAxisScalesBothComponentsIndependently() throws {
        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(multiplier: 2.0))
        let event = try requireScrollEvent(axis1Line: 1, axis2Line: 3, axis1Point: 2, axis2Point: 4)

        let result = processScroll(remapper, event)
        let out = try XCTUnwrap(result)
        let values = axisValues(out)
        XCTAssertEqual(values.a1Line, 2)
        XCTAssertEqual(values.a2Line, 6)
        XCTAssertEqual(values.a1Point, 4)
        XCTAssertEqual(values.a2Point, 8)
    }

    func testShiftConversionPreservesScaledNativeAxis2AndAddsConvertedAxis1() throws {
        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(multiplier: 2.0, shiftHorizontal: true))
        let event = try requireScrollEvent(axis1Line: 1, axis2Line: 3, shift: true)

        let result = processScroll(remapper, event)
        let out = try XCTUnwrap(result)
        let values = axisValues(out)
        XCTAssertEqual(values.a1Line, 0)
        // converted axis1 (1*2=2) + native axis2 (3*2=6) = 8
        XCTAssertEqual(values.a2Line, 8)
    }

    func testAxis1OnlyRegressionStillScalesVertically() throws {
        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(multiplier: 2.0))
        let event = try requireScrollEvent(axis1Line: 2, axis1Fixed: 1.25)

        let result = processScroll(remapper, event)
        let out = try XCTUnwrap(result)
        let values = axisValues(out)
        XCTAssertEqual(values.a1Line, 4)
        XCTAssertEqual(values.a2Line, 0)
        XCTAssertEqual(values.a1Fixed, 2.5, accuracy: 0.0001)
        XCTAssertEqual(values.a2Fixed, 0, accuracy: 0.0001)
    }

    func testInversionAppliesToNativeAxis2AndDualAxis() throws {
        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(multiplier: 2.0, invert: true))

        let axis2Only = try requireScrollEvent(axis2Line: 3, axis2Point: 4, axis2Fixed: 1.5)
        let axis2Out = try XCTUnwrap(processScroll(remapper, axis2Only))
        let axis2Values = axisValues(axis2Out)
        XCTAssertEqual(axis2Values.a2Line, -6)
        XCTAssertEqual(axis2Values.a2Point, -8)
        XCTAssertEqual(axis2Values.a2Fixed, -3.0, accuracy: 0.0001)

        let dual = try requireScrollEvent(axis1Line: 1, axis2Line: 2)
        let dualOut = try XCTUnwrap(processScroll(remapper, dual))
        let dualValues = axisValues(dualOut)
        XCTAssertEqual(dualValues.a1Line, -2)
        XCTAssertEqual(dualValues.a2Line, -4)
    }

    func testPermissionLossResetsScrollResiduals() throws {
        let remapper = InputRemapper()
        // 0.25 accumulates three line ticks before emitting 1.
        remapper.updateProfile(makeProfile(multiplier: 0.25))

        for _ in 0..<2 {
            let event = try requireScrollEvent(axis2Line: 1)
            let out = try XCTUnwrap(processScroll(remapper, event))
            XCTAssertEqual(axisValues(out).a2Line, 0, "Fractional ticks should residual-hold")
        }

        remapper.handlePermissionLoss()

        // After residual reset, another two fractional ticks still do not emit.
        for _ in 0..<2 {
            let event = try requireScrollEvent(axis2Line: 1)
            let out = try XCTUnwrap(processScroll(remapper, event))
            XCTAssertEqual(
                axisValues(out).a2Line,
                0,
                "Permission loss must clear native axis-2 residual"
            )
        }

        let third = try requireScrollEvent(axis2Line: 1)
        let thirdOut = try XCTUnwrap(processScroll(remapper, third))
        XCTAssertEqual(
            axisValues(thirdOut).a2Line,
            0,
            "Third post-reset fractional tick still holds (fresh residual, not pre-loss residue)"
        )

        let fourth = try requireScrollEvent(axis2Line: 1)
        let fourthOut = try XCTUnwrap(processScroll(remapper, fourth))
        XCTAssertEqual(
            axisValues(fourthOut).a2Line,
            1,
            "Fourth post-reset tick completes a fresh residual cycle"
        )
    }

    func testAxis2OnlyNeverFiresWheelUpOrDownActions() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage
        mappings[.wheelDown] = .previousDPIStage

        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(mappings: mappings))
        var nextDPI = 0
        var previousDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        callbacks.onPreviousDPIStage = { previousDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        let upLike = try requireScrollEvent(axis2Line: 3)
        let downLike = try requireScrollEvent(axis2Line: -3)

        XCTAssertNotNil(processScroll(remapper, upLike))
        XCTAssertNotNil(processScroll(remapper, downLike))
        XCTAssertEqual(nextDPI, 0)
        XCTAssertEqual(previousDPI, 0)
    }

    func testWheelActionsRemainAxis1Only() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage
        mappings[.wheelDown] = .previousDPIStage

        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(mappings: mappings))
        var nextDPI = 0
        var previousDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        callbacks.onPreviousDPIStage = { previousDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        let up = try requireScrollEvent(axis1Line: 1, axis2Line: 9)
        let down = try requireScrollEvent(axis1Line: -1, axis2Line: -9)

        let upOut = try XCTUnwrap(processScroll(remapper, up))
        let upValues = axisValues(upOut)
        XCTAssertEqual(upValues.a1Line, 0)
        XCTAssertEqual(upValues.a2Line, 18)

        let downOut = try XCTUnwrap(processScroll(remapper, down))
        let downValues = axisValues(downOut)
        XCTAssertEqual(downValues.a1Line, 0)
        XCTAssertEqual(downValues.a2Line, -18)

        XCTAssertEqual(nextDPI, 1)
        XCTAssertEqual(previousDPI, 1)
    }

    func testMappedDualAxisFiringReturnsScaledAxis2Remainder() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage

        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(multiplier: 2.0, mappings: mappings))
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        let event = try requireScrollEvent(
            axis1Line: 1,
            axis2Line: 3,
            axis1Point: 2,
            axis2Point: 4,
            axis1Fixed: 0.5,
            axis2Fixed: 1.25
        )
        let out = try XCTUnwrap(processScroll(remapper, event))
        let values = axisValues(out)
        XCTAssertEqual(nextDPI, 1)
        XCTAssertEqual(values.a1Line, 0)
        XCTAssertEqual(values.a1Point, 0)
        XCTAssertEqual(values.a1Fixed, 0, accuracy: 0.0001)
        XCTAssertEqual(values.a2Line, 6)
        XCTAssertEqual(values.a2Point, 8)
        XCTAssertEqual(values.a2Fixed, 2.5, accuracy: 0.0001)
    }

    func testMappedDualAxisThrottledTickStillReturnsScaledAxis2Remainder() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage

        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.updateProfile(makeProfile(multiplier: 2.0, mappings: mappings))
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        time = 1.0
        XCTAssertNotNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1, axis2Line: 2)))
        XCTAssertEqual(nextDPI, 1)

        time = 1.010
        let throttled = try requireScrollEvent(
            axis1Line: 1,
            axis2Line: 3,
            axis1Point: 5,
            axis2Point: 4,
            axis1Fixed: 9,
            axis2Fixed: 1.5
        )
        let out = try XCTUnwrap(processScroll(remapper, throttled))
        let values = axisValues(out)
        XCTAssertEqual(nextDPI, 1, "Throttled tick must not re-fire the axis1 action")
        XCTAssertEqual(values.a1Line, 0)
        XCTAssertEqual(values.a1Point, 0)
        XCTAssertEqual(values.a1Fixed, 0, accuracy: 0.0001)
        XCTAssertEqual(values.a2Line, 6)
        XCTAssertEqual(values.a2Point, 8)
        XCTAssertEqual(values.a2Fixed, 3.0, accuracy: 0.0001)
    }

    func testMappedAxis1OnlyStillReturnsNil() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage

        let remapper = InputRemapper()
        remapper.updateProfile(makeProfile(mappings: mappings))
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        XCTAssertEqual(nextDPI, 1)
    }

    func testMappedScrollActionsThrottleBurstWithinWindow() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage

        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.updateProfile(makeProfile(mappings: mappings))
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        for index in 0..<10 {
            time = Double(index) * 0.002
            let event = try requireScrollEvent(axis1Line: 1)
            XCTAssertNil(processScroll(remapper, event))
        }
        XCTAssertEqual(nextDPI, 1)
    }

    func testMappedScrollActionsFireAtExactThrottleThreshold() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage

        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.updateProfile(makeProfile(mappings: mappings))
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        time = 1.0
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        time = 1.059
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        XCTAssertEqual(nextDPI, 1)
        time = 1.060
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        XCTAssertEqual(nextDPI, 2)
    }

    func testMappedScrollDirectionChangeResetsThrottle() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage
        mappings[.wheelDown] = .previousDPIStage

        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.updateProfile(makeProfile(mappings: mappings))
        var nextDPI = 0
        var previousDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        callbacks.onPreviousDPIStage = { previousDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        time = 2.0
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        time = 2.010
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        XCTAssertEqual(nextDPI, 1)
        time = 2.011
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: -1)))
        XCTAssertEqual(previousDPI, 1)
    }

    func testPassthroughScrollUnaffectedByActionThrottle() throws {
        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.updateProfile(makeProfile(multiplier: 2.0))

        for index in 0..<5 {
            time = Double(index) * 0.002
            let event = try requireScrollEvent(axis1Line: 1)
            let result = try XCTUnwrap(processScroll(remapper, event))
            XCTAssertEqual(result.getIntegerValueField(.scrollWheelEventDeltaAxis1), 2)
        }
    }

    func testPermissionLossResetsScrollActionThrottle() throws {
        var mappings = PhysicalControl.defaultButtonMappings()
        mappings[.wheelUp] = .nextDPIStage

        let remapper = InputRemapper()
        var time: TimeInterval = 0
        remapper.monotonicTime = { time }
        remapper.updateProfile(makeProfile(mappings: mappings))
        var nextDPI = 0
        var callbacks = InputRemapper.Callbacks()
        callbacks.onNextDPIStage = { nextDPI += 1 }
        XCTAssertTrue(remapper.setCallbacks(callbacks))

        time = 5.0
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        XCTAssertEqual(nextDPI, 1)

        remapper.handlePermissionLoss()

        time = 5.005
        XCTAssertNil(processScroll(remapper, try requireScrollEvent(axis1Line: 1)))
        XCTAssertEqual(nextDPI, 2, "Permission loss must reset scroll-action throttle")
    }

    /// Converts the remapper's `Unmanaged` result to a managed reference while `event`
    /// is still alive. Never hand a raw `Unmanaged` to an XCTest assertion: the
    /// assertion stringifies its value, and reflecting `Unmanaged` retains the pointer
    /// it holds — which is dangling the moment the source event is released.
    private func processScroll(_ remapper: InputRemapper, _ event: CGEvent) -> CGEvent? {
        let result = remapper.processScrollWheelEvent(event)
        return withExtendedLifetime(event) { result?.takeUnretainedValue() }
    }

}
