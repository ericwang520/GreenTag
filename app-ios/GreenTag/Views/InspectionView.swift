import AVFoundation
import SwiftUI

/// The live AR inspection screen: full-screen camera, real-time stud-spacing
/// measurement, a voice-assistant indicator (the check is conversational), and
/// a verdict card on confirm. Voice (LiveKit) is not wired yet — the indicator
/// and verdict run on-device as a preview.
struct InspectionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private let kind: InspectionKind = .woodStudSpacing

    @State private var spacingIn = 0.0
    @State private var confidence = 0.0
    @State private var lumberDetections: [LumberDetection] = []
    @State private var roboflowStatus = "Starting vision"
    @State private var minimumConfidence = RoboflowLumberDetectorConfiguration.defaultMinimumConfidence
    @State private var debugFrame: RoboflowDebugFrame?

    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isPreparingCamera = false
    @State private var isARSessionVisible = false

    @State private var showDebug = false
    @State private var demoMode = false
    @State private var verdict: Verdict?
    @State private var publishStatus = ""

    private var hasConfirmedMeasurement: Bool {
        confidence >= minimumConfidence && spacingIn > 0
    }

    private var spacingPreview: StudSpacingPreview {
        StudSpacingPreview(measuredInches: spacingIn)
    }

    private var voiceState: AgentVoiceState {
        if verdict != nil { return .speaking }
        return hasConfirmedMeasurement ? .ready : .listening
    }

    private var showManualControls: Bool {
        demoMode || !isARSessionVisible
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isARSessionVisible {
                arLayer
            } else {
                permissionLayer
            }

            VStack(spacing: 12) {
                topBar
                AgentVoiceIndicator(state: voiceState, site: appModel.jobSite, headline: verdict?.headline)
                if showDebug, let debugFrame {
                    RoboflowDebugFramePreview(debugFrame: debugFrame)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer()
                if showManualControls {
                    manualControls
                }
                measurementBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if let verdict {
                verdictOverlay(verdict)
            }
        }
        .preferredColorScheme(.dark)
        .task { await prepareCamera() }
    }

    // MARK: AR layer

    private var arLayer: some View {
        ZStack {
            ARInspectionView(
                roboflowAPIKey: AppSecrets.roboflowAPIKey,
                minimumConfidence: minimumConfidence,
                onMeasurementUpdated: { spacing, conf in
                    guard verdict == nil else { return }
                    spacingIn = spacing
                    confidence = conf
                },
                onDetectionsUpdated: { lumberDetections = $0 },
                onDebugFrameUpdated: { debugFrame = $0 },
                onDetectorStatusUpdated: { roboflowStatus = $0 }
            )
            .ignoresSafeArea()

            ARGuideOverlay(
                spacingIn: spacingIn,
                detections: lumberDetections,
                minimumConfidence: minimumConfidence,
                hasConfirmedMeasurement: hasConfirmedMeasurement
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.55), in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(appModel.jobSite.locationLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.45), in: Capsule())

            Spacer()

            Label(roboflowStatus, systemImage: "eye.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())

            Menu {
                Toggle("Demo mode (manual)", isOn: $demoMode)
                Toggle("Show Roboflow view", isOn: $showDebug)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.55), in: Circle())
            }
        }
    }

    // MARK: Measurement bar

    private var measurementBar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasConfirmedMeasurement ? spacingPreview.status.title : "Scanning studs")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(hasConfirmedMeasurement ? Theme.accent : .orange)
                    Text(hasConfirmedMeasurement
                         ? spacingPreview.detailText
                         : "Need two confident lumber detections")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(hasConfirmedMeasurement ? String(format: "%.2f in", spacingIn) : "--")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(hasConfirmedMeasurement
                         ? "\(Int((confidence * 100).rounded()))% confidence"
                         : "\(lumberDetections.count) lumber")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            Button {
                runCheck()
            } label: {
                Label(hasConfirmedMeasurement ? "Lock & check code" : "Hold steady to lock",
                      systemImage: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(hasConfirmedMeasurement ? .black : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        hasConfirmedMeasurement ? Theme.accent : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasConfirmedMeasurement)

            if !publishStatus.isEmpty {
                Text(publishStatus)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(16)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Manual / demo controls

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isARSessionVisible ? "Demo mode" : "Manual measurement",
                  systemImage: "hand.draw.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))

            HStack {
                Text("Spacing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(value: $spacingIn, in: 12...28, step: 0.25)
                    .tint(Theme.accent)
                Text(String(format: "%.2f in", spacingIn))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 64, alignment: .trailing)
            }

            HStack {
                Text("Confidence")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(value: $confidence, in: 0.0...1.0, step: 0.01)
                    .tint(Theme.accent)
                Text("\(Int((confidence * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Permission layer

    private var permissionLayer: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(permissionTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text(permissionMessage)
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await prepareCamera() }
            } label: {
                Label(isPreparingCamera ? "Starting…" : "Start camera", systemImage: "camera.fill")
                    .font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(isPreparingCamera || cameraAuthorizationStatus == .denied || cameraAuthorizationStatus == .restricted)

            Text("No camera? Use Demo mode below to walk the flow.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(26)
        .frame(maxWidth: 340)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14), lineWidth: 1))
        .padding(24)
        .onAppear { demoMode = true }
    }

    // MARK: Verdict overlay

    private func verdictOverlay(_ verdict: Verdict) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { /* swallow */ }

            VStack {
                Spacer()
                VerdictCard(
                    verdict: verdict,
                    site: appModel.jobSite,
                    onSave: { saveAndExit(verdict) },
                    onContinue: { resumeScanning() }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private func runCheck() {
        guard hasConfirmedMeasurement, verdict == nil else { return }
        let result = FramingCodePreview.verdict(spacingIn: spacingIn, confidence: confidence)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            verdict = result
        }
        Task { await publish() }
    }

    private func saveAndExit(_ verdict: Verdict) {
        let record = InspectionRecord(
            observationID: appModel.nextObservationID(),
            kind: kind,
            site: appModel.jobSite,
            verdict: verdict,
            createdAt: Date()
        )
        appModel.add(record)
        dismiss()
    }

    private func resumeScanning() {
        withAnimation(.easeInOut(duration: 0.25)) {
            verdict = nil
        }
        publishStatus = ""
    }

    @MainActor
    private func prepareCamera() async {
        guard !isPreparingCamera else { return }
        isPreparingCamera = true
        defer { isPreparingCamera = false }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorizationStatus = status

        switch status {
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

    @MainActor
    private func publish() async {
        guard let url = URL(string: appModel.agentEndpoint) else {
            publishStatus = "Invalid agent URL"
            return
        }
        publishStatus = "Sending to agent…"
        let observation = FieldObservation(
            observationID: appModel.nextObservationID(),
            inspectionItem: kind.rawValue,
            location: ObservationLocation(city: appModel.jobSite.city, state: appModel.jobSite.state),
            measurement: ObservationMeasurement(spacingIn: spacingIn, confidence: confidence),
            detections: lumberDetections.map {
                ObservationDetection(objectClass: $0.className, confidence: $0.confidence)
            }
        )
        do {
            let code = try await AgentEventPublisher(endpoint: url).publish(observation)
            publishStatus = "Agent notified (\(code))"
        } catch {
            publishStatus = "Agent offline — showing on-device preview"
        }
    }

    private var permissionTitle: String {
        switch cameraAuthorizationStatus {
        case .authorized: "Ready to inspect"
        case .notDetermined: "Camera access needed"
        case .denied, .restricted: "Camera is off"
        @unknown default: "Camera unavailable"
        }
    }

    private var permissionMessage: String {
        switch cameraAuthorizationStatus {
        case .authorized: "Start the camera to begin AR measurement."
        case .notDetermined: "GreenTag uses ARKit and Roboflow to measure framing on the wall."
        case .denied, .restricted: "Enable camera access in Settings to run a live inspection."
        @unknown default: "Restart the app and try again."
        }
    }
}

// MARK: - Agent voice indicator (placeholder for LiveKit)

enum AgentVoiceState {
    case listening
    case ready
    case speaking

    var title: String {
        switch self {
        case .listening: "Listening — scanning the wall"
        case .ready: "Ready — tap to check code"
        case .speaking: "Inspector speaking"
        }
    }

    var color: Color {
        switch self {
        case .listening: .cyan
        case .ready: .green
        case .speaking: .green
        }
    }

    var isAnimating: Bool { self != .ready }
}

/// Visual stand-in for the conversational agent. When LiveKit voice is wired,
/// this binds to the live session state and the real transcript.
struct AgentVoiceIndicator: View {
    let state: AgentVoiceState
    let site: JobSite
    var headline: String?

    @State private var animate = false

    private var subtitle: String {
        if let headline { return headline }
        return switch state {
        case .listening: "Checking against \(site.city) code…"
        case .ready: "Spacing locked — say the word or tap to check"
        case .speaking: "Comparing to local framing code…"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            waveform
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(state.color)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(state.color.opacity(0.35), lineWidth: 1))
        .onAppear { animate = true }
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(state.color)
                    .frame(width: 3, height: barHeight(i))
                    .animation(
                        state.isAnimating
                            ? .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.1)
                            : .default,
                        value: animate
                    )
            }
        }
        .frame(width: 28, height: 22)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard state.isAnimating else { return 8 }
        let base: [CGFloat] = [10, 18, 14, 20]
        return animate ? base[index] : 6
    }
}

// MARK: - AR overlays (moved from the original ContentView)

private struct ARGuideOverlay: View {
    let spacingIn: Double
    let detections: [LumberDetection]
    let minimumConfidence: Double
    let hasConfirmedMeasurement: Bool

    var body: some View {
        GeometryReader { geometry in
            let pair = selectedPair(in: geometry.size)

            ZStack(alignment: .topLeading) {
                ForEach(detections) { detection in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        Text("\(detection.className) \(Int((detection.confidence * 100).rounded()))%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.orange, in: Capsule())
                            .offset(x: 5, y: -24)
                    }
                    .frame(width: max(detection.frame.width, 24), height: max(detection.frame.height, 24))
                    .position(detection.center)
                }

                if let pair, hasConfirmedMeasurement {
                    Path { path in
                        path.move(to: pair.left)
                        path.addLine(to: pair.right)
                    }
                    .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))

                    guidePoint(at: pair.left)
                    guidePoint(at: pair.right)

                    Text(String(format: "%.2f in", spacingIn))
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.green, in: Capsule())
                        .position(x: (pair.left.x + pair.right.x) / 2, y: pair.left.y - 30)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func guidePoint(at point: CGPoint) -> some View {
        ZStack {
            Circle().stroke(.green, lineWidth: 3).frame(width: 34, height: 34)
            Circle().fill(.green).frame(width: 8, height: 8)
        }
        .position(point)
    }

    private func selectedPair(in size: CGSize) -> (left: CGPoint, right: CGPoint)? {
        let sorted = detections
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.frame.midX < $1.frame.midX }
        guard let first = sorted.first, let last = sorted.last, first.id != last.id else {
            return nil
        }
        return (first.center, last.center)
    }
}

private struct RoboflowDebugFramePreview: View {
    let debugFrame: RoboflowDebugFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Roboflow view")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))

            GeometryReader { geometry in
                let imageSize = debugFrame.image.size
                let drawRect = aspectFitRect(imageSize: imageSize, containerSize: geometry.size)

                ZStack(alignment: .topLeading) {
                    Image(uiImage: debugFrame.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    ForEach(debugFrame.detections) { detection in
                        let rect = scaledRect(detection.frame, imageSize: imageSize, drawRect: drawRect)
                        Rectangle()
                            .stroke(detection.accepted ? .green : .red, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        Text("\(detection.className) \(Int((detection.confidence * 100).rounded()))%")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(detection.accepted ? .green : .red, in: Capsule())
                            .position(x: rect.midX, y: max(8, rect.minY - 8))
                    }
                }
            }
            .frame(width: 150, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
    }

    private func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func scaledRect(_ rect: CGRect, imageSize: CGSize, drawRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGRect(
            x: drawRect.minX + rect.minX * drawRect.width / imageSize.width,
            y: drawRect.minY + rect.minY * drawRect.height / imageSize.height,
            width: rect.width * drawRect.width / imageSize.width,
            height: rect.height * drawRect.height / imageSize.height
        )
    }
}

#Preview {
    InspectionView()
        .environment(AppModel())
}
