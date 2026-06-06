import AVFoundation
import SwiftUI

struct FieldObservation: Encodable {
    let event = "field_observation.updated"
    let source = "greentag_ios"
    let observationID: String
    let inspectionItem = "wood_stud_spacing"
    let location: ObservationLocation
    let measurement: ObservationMeasurement
    let detections: [ObservationDetection]
    let questionForAgent = "Does this pass local framing code, and what should I do next?"

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

struct ContentView: View {
    @State private var spacingIn = 15.25
    @State private var confidence = 0.86
    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isPreparingCamera = false
    @State private var isARSessionVisible = false

    private var observation: FieldObservation {
        FieldObservation(
            observationID: "obs_demo_001",
            location: ObservationLocation(city: "San Francisco", state: "CA"),
            measurement: ObservationMeasurement(spacingIn: spacingIn, confidence: confidence),
            detections: [
                ObservationDetection(objectClass: "lumber", confidence: 0.91),
                ObservationDetection(objectClass: "lumber", confidence: 0.88)
            ]
        )
    }

    private var observationJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(observation),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isARSessionVisible {
                ARInspectionView()
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 18) {
                header

                if !isARSessionVisible {
                    cameraStartPanel
                }

                Spacer()

                measurementPanel
                agentPayloadPanel
            }
            .padding(18)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GreenTag", systemImage: "viewfinder")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.green)

            Text("AR-assisted framing inspection agent")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var cameraStartPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cameraStartTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Text(cameraStartMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await prepareCamera()
                }
            } label: {
                Label(isPreparingCamera ? "Starting" : "Start AR Camera", systemImage: "camera.viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isPreparingCamera || cameraAuthorizationStatus == .denied || cameraAuthorizationStatus == .restricted)
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var measurementPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Center-to-center spacing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))

                    Text(String(format: "%.2f in", spacingIn))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Vision confidence")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))

                    Text("\(Int((confidence * 100).rounded()))%")
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
            }

            Divider().background(.white.opacity(0.16))

            VStack(spacing: 10) {
                Slider(value: $spacingIn, in: 12...28, step: 0.25)
                    .tint(.green)

                Slider(value: $confidence, in: 0.3...1, step: 0.01)
                    .tint(.green)
            }
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var agentPayloadPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Agent payload", systemImage: "waveform.and.magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Text("schema v2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            }

            ScrollView {
                Text(observationJSON)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 260)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var cameraStartTitle: String {
        switch cameraAuthorizationStatus {
        case .authorized:
            "Ready for AR inspection"
        case .notDetermined:
            "Camera access required"
        case .denied, .restricted:
            "Camera access is off"
        @unknown default:
            "Camera status unknown"
        }
    }

    private var cameraStartMessage: String {
        switch cameraAuthorizationStatus {
        case .authorized:
            "Start the camera to begin the ARKit measurement loop."
        case .notDetermined:
            "GreenTag needs camera access for ARKit wall tracking and Roboflow lumber detection."
        case .denied, .restricted:
            "Enable camera access in Settings before running the AR inspection."
        @unknown default:
            "Restart the app and try again."
        }
    }

    @MainActor
    private func prepareCamera() async {
        guard !isPreparingCamera else { return }
        isPreparingCamera = true
        defer { isPreparingCamera = false }

        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorizationStatus = currentStatus

        switch currentStatus {
        case .authorized:
            isARSessionVisible = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            isARSessionVisible = granted
        case .denied, .restricted:
            isARSessionVisible = false
        @unknown default:
            isARSessionVisible = false
        }
    }
}

#Preview {
    ContentView()
}
