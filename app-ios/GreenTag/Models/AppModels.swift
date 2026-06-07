import Foundation

// MARK: - Job site

/// A construction job site. Drives the `location` field on every observation so
/// the agent retrieves the right jurisdiction's code (SF / Seattle / ...).
struct JobSite: Identifiable, Hashable {
    let id: UUID
    var name: String
    var city: String
    var state: String

    init(id: UUID = UUID(), name: String, city: String, state: String) {
        self.id = id
        self.name = name
        self.city = city
        self.state = state
    }

    var locationLine: String { "\(city), \(state)" }
}

// MARK: - Inspection kind

/// What is being inspected. Today only stud spacing; new kinds extend here and
/// map to the `inspection_item` snake_case value in the schema.
enum InspectionKind: String, CaseIterable, Identifiable {
    case woodStudSpacing = "wood_stud_spacing"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .woodStudSpacing: "Wood stud spacing"
        }
    }

    var subtitle: String {
        switch self {
        case .woodStudSpacing: "Center-to-center framing layout"
        }
    }

    var systemImage: String {
        switch self {
        case .woodStudSpacing: "ruler"
        }
    }
}

// MARK: - Verdict

/// Compliance outcome shown on the verdict card and stored in history.
enum VerdictStatus: String {
    case pass
    case review
    case fail
    case pending

    var title: String {
        switch self {
        case .pass: "PASS"
        case .review: "NEEDS REVIEW"
        case .fail: "FAIL"
        case .pending: "CHECKING"
        }
    }

    var systemImage: String {
        switch self {
        case .pass: "checkmark.seal.fill"
        case .review: "exclamationmark.triangle.fill"
        case .fail: "xmark.seal.fill"
        case .pending: "waveform"
        }
    }
}

/// The result the agent would speak. Until LiveKit voice is wired, the app shows
/// an on-device *preview* (`isPreview == true`); the agent's voice gives the
/// official ruling, and the cited clause must come from the code library.
struct Verdict {
    var status: VerdictStatus
    var headline: String
    var detail: String
    var citation: String
    var clause: String
    var spacingIn: Double
    var confidence: Double
    var isPreview: Bool
}

/// One completed inspection — a row in the home History list.
struct InspectionRecord: Identifiable {
    let id = UUID()
    let observationID: String
    let kind: InspectionKind
    let site: JobSite
    let verdict: Verdict
    let createdAt: Date
}

// MARK: - Local framing-code preview

/// On-device, tentative reading against the common 16" OC layout. NOT the
/// official ruling — the agent retrieves the real clause and speaks the verdict.
/// Used only to populate the card while LiveKit voice is not yet connected.
enum FramingCodePreview {
    static let citation = "IRC R602.3(5)"
    static let clause =
        "Studs shall be spaced not more than 16 inches on center (24 inches on center is permitted for certain assemblies)."

    static func verdict(spacingIn: Double, confidence: Double) -> Verdict {
        let preview = StudSpacingPreview(measuredInches: spacingIn)

        let status: VerdictStatus = switch preview.status {
        case .likelyOnLayout: .pass
        case .checkLayout: .review
        case .likelyOffLayout: .fail
        }

        let headline = switch status {
        case .pass: "On layout — likely passes"
        case .review: "Borderline — recheck layout"
        case .fail: "Off layout — likely fails"
        case .pending: "Checking against local code"
        }

        return Verdict(
            status: status,
            headline: headline,
            detail: preview.detailText,
            citation: citation,
            clause: clause,
            spacingIn: spacingIn,
            confidence: confidence,
            isPreview: true
        )
    }
}
