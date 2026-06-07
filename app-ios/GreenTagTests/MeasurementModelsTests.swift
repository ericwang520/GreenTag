import XCTest
@testable import GreenTag

final class MeasurementModelsTests: XCTestCase {
    func testConvertsInchesToMeters() {
        XCTAssertEqual(DistanceFormatter.meters(fromInches: 16), 0.4064, accuracy: 0.0001)
    }

    func testConvertsMetersToInches() {
        XCTAssertEqual(DistanceFormatter.inches(fromMeters: 0.4064), 16, accuracy: 0.0001)
    }

    func testFormatsInchesBelowTwoFeet() {
        XCTAssertEqual(DistanceFormatter.imperialString(inches: 16), "16.00 in")
    }

    func testFormatsFeetAndInchesAtTwoFeetOrMore() {
        XCTAssertEqual(DistanceFormatter.imperialString(inches: 48), "4 ft 0.00 in")
    }

    func testSpacingPreviewPassesNearSixteenInches() {
        let preview = StudSpacingPreview(measuredInches: 15.25)

        XCTAssertEqual(preview.status, .likelyOnLayout)
        XCTAssertTrue(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "0.75 in under the 16 in limit")
    }

    func testSpacingPreviewFailsWhenTooWide() {
        let preview = StudSpacingPreview(measuredInches: 18)

        XCTAssertEqual(preview.status, .likelyOffLayout)
        XCTAssertFalse(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "2.00 in over the 16 in limit")
    }

    // "Max 16 on center" is an upper bound: tighter spacing is more studs, which
    // is compliant. This must pass, exactly as the voice agent rules it (the card
    // and the spoken verdict share one rule).
    func testSpacingPreviewPassesWhenTighter() {
        let preview = StudSpacingPreview(measuredInches: 14)

        XCTAssertEqual(preview.status, .likelyOnLayout)
        XCTAssertTrue(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "2.00 in under the 16 in limit")
    }

    // 16.3" is over 16 but within the 0.5" tolerance — passes, matching the agent.
    func testSpacingPreviewPassesWithinTolerance() {
        let preview = StudSpacingPreview(measuredInches: 16.3)

        XCTAssertTrue(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "0.30 in over 16 in, within tolerance")
    }

    func testLowConfidenceVerdictAsksForReaim() {
        let verdict = FramingCodePreview.verdict(spacingIn: 15.25, confidence: 0.5)

        XCTAssertEqual(verdict.status, .review)
    }

    func testConfidentVerdictRules() {
        let verdict = FramingCodePreview.verdict(spacingIn: 15.25, confidence: 0.9)

        XCTAssertEqual(verdict.status, .pass)
    }
}
