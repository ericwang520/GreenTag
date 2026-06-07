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
        XCTAssertEqual(preview.toleranceViolationInches, 1.5, accuracy: 0.001)
    }

    // "Max 16 on center" is an upper bound: tighter spacing is more studs, which
    // is compliant. This must pass, exactly as the voice agent rules it (the card
    // and the spoken verdict share one rule).
    func testSpacingPreviewPassesWhenTighter() {
        let preview = StudSpacingPreview(measuredInches: 14)

        XCTAssertEqual(preview.status, .likelyOnLayout)
        XCTAssertTrue(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "2.00 in under the 16 in limit")
        XCTAssertEqual(preview.toleranceViolationInches, 0)
    }

    // 16.3" is over 16 but within the 0.5" tolerance — passes, matching the agent.
    func testSpacingPreviewPassesWithinTolerance() {
        let preview = StudSpacingPreview(measuredInches: 16.3)

        XCTAssertTrue(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "0.30 in over 16 in, within tolerance")
    }

    func testFailingMeasurementsHaveHigherInspectionPriorityThanPassingMeasurements() {
        let passing = StudSpacingPreview(measuredInches: 16)
        let failing = StudSpacingPreview(measuredInches: 19.3)

        XCTAssertGreaterThan(failing.inspectionPriority, passing.inspectionPriority)
        XCTAssertEqual(failing.toleranceViolationInches, 2.8, accuracy: 0.001)
    }

    func testVerdictSummarizesMultipleMeasuredSpans() {
        let verdict = FramingCodePreview.verdict(
            spacingIn: 19.3,
            confidence: 0.86,
            segments: [
                LumberMeasurementSegment(left: .zero, right: .zero, spacingIn: 16, confidence: 0.89),
                LumberMeasurementSegment(left: .zero, right: .zero, spacingIn: 19.3, confidence: 0.86),
            ]
        )

        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(verdict.spans.count, 2)
        XCTAssertEqual(verdict.headline, "1 of 2 measured spans need recheck")
        XCTAssertTrue(verdict.detail.contains("Left: 16.00 in pass"))
        XCTAssertTrue(verdict.detail.contains("Right: 19.30 in recheck"))
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
