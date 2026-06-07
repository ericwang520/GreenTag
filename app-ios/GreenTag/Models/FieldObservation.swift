import Foundation

/// Wire payload sent to the agent `/events` endpoint. Mirrors schema.md
/// (FieldObservation v2): vision sends raw measurements only — never a verdict.
struct FieldObservation: Encodable {
    let event = "field_observation.updated"
    let source = "greentag_ios"
    let observationID: String
    let inspectionItem: String
    let location: ObservationLocation
    let measurement: ObservationMeasurement
    let detections: [ObservationDetection]
    let questionForAgent: String

    init(
        observationID: String,
        inspectionItem: String = InspectionKind.woodStudSpacing.rawValue,
        location: ObservationLocation,
        measurement: ObservationMeasurement,
        detections: [ObservationDetection],
        questionForAgent: String = "Does this pass local framing code, and what should I do next?"
    ) {
        self.observationID = observationID
        self.inspectionItem = inspectionItem
        self.location = location
        self.measurement = measurement
        self.detections = detections
        self.questionForAgent = questionForAgent
    }

    enum CodingKeys: String, CodingKey {
        case event
        case source
        case observationID = "observation_id"
        case inspectionItem = "inspection_item"
        case location
        case measurement
        case detections
        case questionForAgent = "question_for_agent"
    }
}

struct ObservationLocation: Encodable {
    let city: String
    let state: String
}

struct ObservationMeasurement: Encodable {
    let spacingIn: Double
    let confidence: Double
    let method = "center_to_center"

    enum CodingKeys: String, CodingKey {
        case spacingIn = "spacing_in"
        case confidence
        case method
    }
}

struct ObservationDetection: Encodable {
    let objectClass: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case objectClass = "class"
        case confidence
    }
}
