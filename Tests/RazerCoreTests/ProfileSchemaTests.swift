import XCTest
@testable import RazerCore

final class ProfileSchemaTests: XCTestCase {
    func testLegacyProfileJSONDecodesWithDefaults() throws {
        let json = """
        {
          "activeStage": 2,
          "autoReapplyEnabled": true,
          "dpiStages": [400, 800, 1600],
          "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
          "name": "Legacy",
          "pollingRateHz": 1000
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(MouseProfile.self, from: json)
        XCTAssertEqual(profile.name, "Legacy")
        XCTAssertTrue(profile.remapperEnabled)
        XCTAssertEqual(profile.buttonMappings.count, PhysicalControl.allCases.count)
        XCTAssertEqual(profile.buttonMappings[.leftClick], .passthrough)
        XCTAssertEqual(profile.wheelSettings, .default)
    }

    func testMappingWarningWhenBothPrimaryClicksUnsafe() {
        var profile = MouseProfile(
            name: "Risky",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        profile.buttonMappings[.leftClick] = .disabled
        profile.buttonMappings[.rightClick] = .keyboardShortcut(KeyboardShortcut(keyCode: 36, modifierFlags: 0))
        XCTAssertEqual(ProfileMappingValidator.warnings(for: profile), [.bothPrimaryClicksDisabledOrRemapped])
    }

    func testSafePrimaryClickRemapToMouseButton() {
        var profile = MouseProfile(
            name: "Swap",
            dpiStages: [800],
            activeStage: 1,
            pollingRateHz: 1000
        )
        profile.buttonMappings[.leftClick] = .mouseButton(.right)
        profile.buttonMappings[.rightClick] = .mouseButton(.left)
        XCTAssertTrue(ProfileMappingValidator.warnings(for: profile).isEmpty)
    }
}
