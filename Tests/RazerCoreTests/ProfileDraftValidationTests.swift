import XCTest
@testable import RazerCore

final class ProfileDraftValidationTests: XCTestCase {
    private func baseDraft(stages: [String] = ["800", "1600"]) -> ProfileDraft {
        ProfileDraft(
            name: "Test",
            stageTexts: stages,
            activeStage: 1,
            pollingRateHz: 1000,
            limits: .viperV3HyperSpeed
        )
    }

    func testIntermediateEmptyTextIsInvalidWithoutMutatingParse() {
        var draft = baseDraft()
        draft.stageTexts[0] = ""
        XCTAssertFalse(draft.isValid)
        XCTAssertEqual(draft.stageErrors[0], "Enter a DPI value.")
        XCTAssertThrowsError(try draft.validatedHardware())
    }

    func testNonnumericTextIsInvalid() {
        var draft = baseDraft()
        draft.stageTexts[1] = "abc"
        XCTAssertFalse(draft.isValid)
        XCTAssertEqual(draft.stageErrors[1], "DPI must be a whole number.")
    }

    func testOutOfRangeValuesAreInvalid() {
        var draft = baseDraft(stages: ["50", "800"])
        XCTAssertFalse(draft.isValid)
        XCTAssertNotNil(draft.stageErrors[0])

        draft = baseDraft(stages: ["800", "40000"])
        XCTAssertFalse(draft.isValid)
        XCTAssertNotNil(draft.stageErrors[1])
    }

    func testValidCorrectionBecomesCommitable() throws {
        var draft = baseDraft(stages: ["", "1600"])
        XCTAssertFalse(draft.isValid)
        draft.stageTexts[0] = "800"
        XCTAssertTrue(draft.isValid)
        let hardware = try draft.validatedHardware()
        XCTAssertEqual(hardware.stages, [800, 1600])
        XCTAssertEqual(hardware.activeStage, 1)
        XCTAssertEqual(hardware.pollingRateHz, 1000)
    }

    func testActiveStageValidatedAgainstParsedCount() {
        var draft = baseDraft(stages: ["800"])
        draft.activeStage = 2
        XCTAssertFalse(draft.isValid)
        XCTAssertNotNil(draft.activeStageError)
    }

    func testApplyingDraftUpdatesProfileOnlyWhenValid() throws {
        let profile = MouseProfile(
            name: "Original",
            dpiStages: [400, 800],
            activeStage: 2,
            pollingRateHz: 500
        )
        var draft = ProfileDraft(profile: profile, limits: .viperV3HyperSpeed)
        draft.stageTexts = ["1200", "2400"]
        draft.activeStage = 1
        draft.pollingRateHz = 1000
        draft.name = "Updated"

        let updated = try draft.applying(to: profile)
        XCTAssertEqual(updated.dpiStages, [1200, 2400])
        XCTAssertEqual(updated.activeStage, 1)
        XCTAssertEqual(updated.pollingRateHz, 1000)
        XCTAssertEqual(updated.name, "Updated")
    }

    func testPersistenceStatusFailedRepresentsSaveFailure() {
        let status = PersistenceStatus.failed("disk full")
        guard case let .failed(message) = status else {
            return XCTFail("Expected failed")
        }
        XCTAssertEqual(message, "disk full")
        XCTAssertNotEqual(status, .clean)
        XCTAssertNotEqual(status, .dirty)
    }

    func testRequiredFlushBlockedWhileDraftInvalid() {
        var draft = baseDraft(stages: ["", "1600"])
        XCTAssertNotNil(ProfileDraft.requiredFlushBlockReason(drafts: [draft]))
        draft.stageTexts[0] = "800"
        XCTAssertNil(ProfileDraft.requiredFlushBlockReason(drafts: [draft]))
    }
}
