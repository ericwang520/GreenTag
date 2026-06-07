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
    var spans: [VerdictSpan] = []
}

struct VerdictSpan: Identifiable {
    let id = UUID()
    var label: String
    var spacingIn: Double
    var confidence: Double
    var passes: Bool
    var detail: String
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
    // Below this measurement confidence the agent says "re-aim" instead of ruling
    // (events.py LOW_CONFIDENCE_THRESHOLD). The card mirrors that so it never
    // shows a pass/fail the voice won't back up.
    static let minConfidence = 0.85

    static func verdict(
        spacingIn: Double,
        confidence: Double,
        segments: [LumberMeasurementSegment] = []
    ) -> Verdict {
        let spans = verdictSpans(from: segments, fallbackSpacingIn: spacingIn, fallbackConfidence: confidence)
        let primarySpan = spans.first(where: { !$0.passes }) ?? spans.first
        let preview = StudSpacingPreview(measuredInches: primarySpan?.spacingIn ?? spacingIn)

        // Low confidence on any measured span: don't rule — ask for a re-aim,
        // mirroring the voice agent's confidence gate so the card never shows a
        // pass/fail the voice won't back up.
        let minConfidenceSeen = spans.map(\.confidence).min() ?? confidence
        guard minConfidenceSeen >= minConfidence else {
            return Verdict(
                status: .review,
                headline: "Low confidence — re-aim and hold steady",
                detail: "Reading is approximate; rescan before relying on it.",
                citation: citation,
                clause: clause,
                spacingIn: primarySpan?.spacingIn ?? spacingIn,
                confidence: minConfidenceSeen,
                isPreview: true,
                spans: spans
            )
        }

        let status: VerdictStatus = spans.allSatisfy(\.passes) ? .pass : .fail

        let headline = switch status {
        case .pass: spans.count > 1 ? "All measured spans are on layout" : "On layout — likely passes"
        case .review: "Borderline — recheck layout"
        case .fail:
            "\(spans.filter { !$0.passes }.count) of \(spans.count) measured spans need recheck"
        case .pending: "Checking against local code"
        }

        let detail = spans.count > 1
            ? spans.map { "\($0.label): \(String(format: "%.2f in", $0.spacingIn)) \($0.passes ? "pass" : "recheck")" }.joined(separator: "; ")
            : preview.detailText

        return Verdict(
            status: status,
            headline: headline,
            detail: detail,
            citation: citation,
            clause: clause,
            spacingIn: primarySpan?.spacingIn ?? spacingIn,
            confidence: spans.map(\.confidence).min() ?? confidence,
            isPreview: true,
            spans: spans
        )
    }

    private static func verdictSpans(
        from segments: [LumberMeasurementSegment],
        fallbackSpacingIn: Double,
        fallbackConfidence: Double
    ) -> [VerdictSpan] {
        let sourceSegments = segments.isEmpty
            ? [LumberMeasurementSegment(left: .zero, right: .zero, spacingIn: fallbackSpacingIn, confidence: fallbackConfidence)]
            : segments

        return sourceSegments.enumerated().map { index, segment in
            let preview = StudSpacingPreview(measuredInches: segment.spacingIn)
            return VerdictSpan(
                label: spanLabel(for: index),
                spacingIn: segment.spacingIn,
                confidence: segment.confidence,
                passes: preview.passesWithTolerance,
                detail: preview.detailText
            )
        }
    }

    private static func spanLabel(for index: Int) -> String {
        switch index {
        case 0: "Left"
        case 1: "Right"
        default: "Span \(index + 1)"
        }
    }
}
