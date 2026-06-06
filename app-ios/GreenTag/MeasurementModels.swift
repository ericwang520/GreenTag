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
            "Looks near 16 in OC"
        case .checkLayout:
            "Recheck layout"
        case .likelyOffLayout:
            "Likely off layout"
        }
    }
}

struct StudSpacingPreview {
    let measuredInches: Double
    let targetInches: Double

    init(measuredInches: Double, targetInches: Double = 16.0) {
        self.measuredInches = measuredInches
        self.targetInches = targetInches
    }

    var deltaInches: Double {
        measuredInches - targetInches
    }

    var absoluteDeltaInches: Double {
        abs(deltaInches)
    }

    var status: SpacingPreviewStatus {
        if absoluteDeltaInches <= 0.5 {
            return .likelyOnLayout
        }

        if absoluteDeltaInches <= 1.5 {
            return .checkLayout
        }

        return .likelyOffLayout
    }

    var detailText: String {
        let direction = deltaInches >= 0 ? "wide" : "short"
        return String(format: "%.2f in %@ of 16 in", absoluteDeltaInches, direction)
    }
}
