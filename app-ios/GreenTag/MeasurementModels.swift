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
    // Slack on the comparison, in inches, to absorb measurement noise. Matches
    // the agent's SPACING_TOLERANCE_IN (events.py) so the on-device card and the
    // spoken verdict never disagree.
    static let defaultToleranceInches = 0.5

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

    var maxAllowedInches: Double {
        targetInches + toleranceInches
    }

    /// "Max 16 on center" is an upper bound: tighter spacing (more studs) is
    /// compliant. Mirrors the agent's evaluate_compliance (spacing <= max + tol),
    /// so a 14-inch reading passes here exactly as it does in the voice verdict.
    var passesWithTolerance: Bool {
        measuredInches <= maxAllowedInches
    }

    /// How far the reading exceeds the allowed maximum. Upper-bound only: tighter
    /// spacing is compliant (more studs), so it never "violates". Zero when within
    /// the limit. Mirrors the agent's rule.
    var toleranceViolationInches: Double {
        max(0, measuredInches - maxAllowedInches)
    }

    /// Ranking used to pick which span to surface first. Failing spans always
    /// outrank passing ones; among failing, the worse the overage the higher;
    /// among passing, the closer to the limit the higher (more worth a glance).
    var inspectionPriority: Double {
        if passesWithTolerance {
            return measuredInches
        }

        return 1_000 + toleranceViolationInches
    }

    var status: SpacingPreviewStatus {
        passesWithTolerance ? .likelyOnLayout : .likelyOffLayout
    }

    var detailText: String {
        if passesWithTolerance {
            if measuredInches <= targetInches {
                return String(format: "%.2f in under the %.0f in limit", targetInches - measuredInches, targetInches)
            }
            return String(format: "%.2f in over %.0f in, within tolerance", measuredInches - targetInches, targetInches)
        }
        return String(format: "%.2f in over the %.0f in limit", measuredInches - targetInches, targetInches)
    }
}
