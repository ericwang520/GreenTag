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
        XCTAssertEqual(preview.detailText, "0.75 in from 16 in target")
    }

    func testSpacingPreviewFailsWhenTooWide() {
        let preview = StudSpacingPreview(measuredInches: 18)

        XCTAssertEqual(preview.status, .likelyOffLayout)
        XCTAssertFalse(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "1.00 in over 16 in +/- 1 in")
    }

    func testSpacingPreviewFailsWhenTooTight() {
        let preview = StudSpacingPreview(measuredInches: 14)

        XCTAssertEqual(preview.status, .likelyOffLayout)
        XCTAssertFalse(preview.passesWithTolerance)
        XCTAssertEqual(preview.detailText, "1.00 in short of 16 in +/- 1 in")
    }
}
