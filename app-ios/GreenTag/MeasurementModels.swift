import Foundation

enum DistanceFormatter {
    static let metersPerInch = 0.0254
    static let inchesPerFoot = 12.0

    static func meters(fromInches inches: Double) -> Double {
        inches * metersPerInch
    }

    static func inches(fromMeters meters: Double) -> Double {
        meters / metersPerInch
    }

    static func imperialString(inches: Double) -> String {
        guard inches >= 24 else {
            return String(format: "%.2f in", inches)
        }

        let feet = Int(inches / inchesPerFoot)
        let remainingInches = inches - Double(feet) * inchesPerFoot
        return String(format: "%d ft %.2f in", feet, remainingInches)
    }
}

enum SpacingPreviewStatus {
    case likelyOnLayout
    case checkLayout
    case likelyOffLayout

    var title: String {
        switch self {
        case .likelyOnLayout:
            "Meets spacing code"
        case .checkLayout:
            "Pass within tolerance"
        case .likelyOffLayout:
            "Recheck spacing"
        }
    }
}

struct StudSpacingPreview {
    static let defaultMaxSpacingInches = 16.0
    static let defaultToleranceInches = 12.0

    let measuredInches: Double
    let targetInches: Double
    let toleranceInches: Double

    init(
        measuredInches: Double,
        targetInches: Double = Self.defaultMaxSpacingInches,
        toleranceInches: Double = Self.defaultToleranceInches
    ) {
        self.measuredInches = measuredInches
        self.targetInches = targetInches
        self.toleranceInches = toleranceInches
    }

    var deltaInches: Double {
        measuredInches - targetInches
    }

    var absoluteDeltaInches: Double {
        abs(deltaInches)
    }

    var maxAllowedInches: Double {
        targetInches + toleranceInches
    }

    var passesWithTolerance: Bool {
        measuredInches <= maxAllowedInches
    }

    var status: SpacingPreviewStatus {
        if measuredInches <= targetInches {
            return .likelyOnLayout
        }

        if passesWithTolerance {
            return .checkLayout
        }

        return .likelyOffLayout
    }

    var detailText: String {
        if measuredInches <= targetInches {
            return String(format: "%.2f in within %.0f in max", targetInches - measuredInches, targetInches)
        }

        if passesWithTolerance {
            return String(format: "%.2f in over max, within 1 ft tolerance", measuredInches - targetInches)
        }

        return String(format: "%.2f in over 1 ft tolerance", measuredInches - maxAllowedInches)
    }
}
