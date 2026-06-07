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
    case likelyOffLayout

    var title: String {
        switch self {
        case .likelyOnLayout:
            "Meets spacing code"
        case .likelyOffLayout:
            "Recheck spacing"
        }
    }
}

struct StudSpacingPreview {
    static let defaultMaxSpacingInches = 16.0
    static let defaultToleranceInches = 1.0

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

    var minAllowedInches: Double {
        targetInches - toleranceInches
    }

    var maxAllowedInches: Double {
        targetInches + toleranceInches
    }

    var passesWithTolerance: Bool {
        measuredInches >= minAllowedInches && measuredInches <= maxAllowedInches
    }

    var status: SpacingPreviewStatus {
        if passesWithTolerance {
            return .likelyOnLayout
        }

        return .likelyOffLayout
    }

    var detailText: String {
        if passesWithTolerance {
            return String(format: "%.2f in from %.0f in target", absoluteDeltaInches, targetInches)
        }

        if measuredInches < minAllowedInches {
            return String(format: "%.2f in short of %.0f in +/- %.0f in", minAllowedInches - measuredInches, targetInches, toleranceInches)
        }

        return String(format: "%.2f in over %.0f in +/- %.0f in", measuredInches - maxAllowedInches, targetInches, toleranceInches)
    }
}
