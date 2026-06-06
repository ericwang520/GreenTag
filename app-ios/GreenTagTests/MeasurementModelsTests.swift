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
        let preview = StudSpacingPreview(measuredInches: 16.25)

        XCTAssertEqual(preview.status, .likelyOnLayout)
        XCTAssertEqual(preview.detailText, "0.25 in wide of 16 in")
    }

    func testSpacingPreviewWarnsNearLayoutBoundary() {
        let preview = StudSpacingPreview(measuredInches: 17.25)

        XCTAssertEqual(preview.status, .checkLayout)
        XCTAssertEqual(preview.detailText, "1.25 in wide of 16 in")
    }

    func testSpacingPreviewFailsFarFromLayout() {
        let preview = StudSpacingPreview(measuredInches: 20)

        XCTAssertEqual(preview.status, .likelyOffLayout)
        XCTAssertEqual(preview.detailText, "4.00 in wide of 16 in")
    }
}
