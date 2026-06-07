import AVFoundation
import SwiftUI

/// The live AR inspection screen: full-screen camera, real-time stud-spacing
/// measurement, a live voice link to the agent over LiveKit (the check is
/// conversational), and a verdict card on confirm. The measurement is sent to
/// the agent over the room's data channel; the agent announces the ruling by
/// voice. The card shows an on-device preview alongside.
struct InspectionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var voice = VoiceAgentSession(
        backendBaseURL: URL(string: "https://greentag-backend-production.up.railway.app")!
    )

    private let kind: InspectionKind = .woodStudSpacing

    @State private var spacingIn = 0.0
    @State private var confidence = 0.0
    @State private var lumberDetections: [LumberDetection] = []
    @State private var measurementSegments: [LumberMeasurementSegment] = []
    @State private var roboflowStatus = AppSecrets.roboflowAPIKey.isEmpty ? "Missing Roboflow key" : "Starting vision"
    @State private var minimumConfidence = RoboflowLumberDetectorConfiguration.defaultMinimumConfidence
    @State private var debugFrame: RoboflowDebugFrame?

    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isPreparingCamera = false
    @State private var isARSessionVisible = false

    @State private var showDebug = false
    @State private var demoMode = false
    @State private var verdict: Verdict?
    @State private var inspectionChecks: [ObservationInspectionCheck] = []

    private var hasConfirmedMeasurement: Bool {
        confidence >= minimumConfidence && spacingIn > 0
    }

    private var spacingPreview: StudSpacingPreview {
        StudSpacingPreview(measuredInches: spacingIn)
    }

    private var showManualControls: Bool {
        demoMode || !isARSessionVisible
    }

    private var connectionNote: String {
        switch voice.phase {
        case .idle: ""
        case .connecting: "Connecting to inspector…"
        case .connected:
            if voice.muted { "Muted — tap the mic to talk" }
            else if voice.agentState == .speaking { "Inspector speaking…" }
            else { "Listening — just ask, like “is this one okay?”" }
        case .failed: "Voice offline — showing on-device preview"
        }
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
                AgentVoiceIndicator(
                    state: voice.agentState,
                    transcript: voice.agentTranscript,
                    muted: voice.muted,
                    micActive: voice.isMicEnabled,
                    onToggleMute: { voice.toggleMute() }
                )
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
        .task { await connectVoice() }
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
                    // Keep the agent's live reading fresh so "is this one ok?"
                    // works hands-free, before any lock tap. Throttled in-session.
                    streamReadingToAgent(spacing: spacing, confidence: conf)
                },
                onMeasurementSegmentsUpdated: { segments in
                    guard verdict == nil else { return }
                    measurementSegments = segments
                    if let primarySegment = selectedPrimarySegment(from: segments) {
                        spacingIn = primarySegment.spacingIn
                        confidence = primarySegment.confidence
                    }
                },
                onDetectionsUpdated: { lumberDetections = $0 },
                onDebugFrameUpdated: { debugFrame = $0 },
                onDetectorStatusUpdated: { roboflowStatus = $0 }
            )
            .ignoresSafeArea()

            ARGuideOverlay(
                spacingIn: spacingIn,
                detections: lumberDetections,
                segments: measurementSegments,
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
                closeInspection()
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

            if !connectionNote.isEmpty {
                Label(connectionNote, systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(voice.isConnected ? Theme.accent.opacity(0.9) : .white.opacity(0.55))
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
        let observationID = appModel.nextObservationID()
        let result = FramingCodePreview.verdict(
            spacingIn: spacingIn,
            confidence: confidence,
            segments: measurementSegments
        )
        let currentCheck = inspectionCheck(observationID: observationID, verdict: result)
        // announce=true: this tap asks the agent to speak the verdict out loud.
        let observation = makeObservation(
            observationID: observationID,
            spacingIn: spacingIn,
            confidence: confidence,
            announce: true,
            currentCheck: currentCheck
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            verdict = result
        }
        inspectionChecks.append(currentCheck)
        // Hand the raw measurement to the agent over the data channel; it
        // retrieves the clause and announces the ruling by voice.
        Task { await voice.send(observation) }
    }

    /// Push the live reading to the agent silently (announce=false) so its
    /// get_current_reading tool is always current — this is what lets the
    /// contractor just point and ask, no button. Throttled inside the session.
    private func streamReadingToAgent(spacing: Double, confidence conf: Double) {
        guard voice.isConnected, conf >= minimumConfidence, spacing > 0 else { return }
        let observation = makeObservation(
            observationID: "obs_ios_live",
            spacingIn: spacing,
            confidence: conf,
            announce: false
        )
        Task { await voice.streamReading(observation, spacingIn: spacing) }
    }

    private func makeObservation(
        observationID: String,
        spacingIn: Double,
        confidence: Double,
        announce: Bool,
        currentCheck: ObservationInspectionCheck? = nil
    ) -> FieldObservation {
        FieldObservation(
            observationID: observationID,
            inspectionItem: kind.rawValue,
            location: ObservationLocation(city: appModel.jobSite.city, state: appModel.jobSite.state),
            measurement: ObservationMeasurement(spacingIn: spacingIn, confidence: confidence),
            measurements: observationMeasurements(),
            inspectionSummary: ObservationInspectionSummary(
                checks: inspectionChecks + (currentCheck.map { [$0] } ?? []),
                latestAgentAnnouncement: voice.agentTranscript.isEmpty ? nil : voice.agentTranscript
            ),
            detections: lumberDetections.map {
                ObservationDetection(objectClass: $0.className, confidence: $0.confidence)
            },
            announce: announce
        )
    }

    private func observationMeasurements() -> [ObservationMeasurement] {
        guard !measurementSegments.isEmpty else {
            return [ObservationMeasurement(spacingIn: spacingIn, confidence: confidence, label: "primary")]
        }

        return measurementSegments.enumerated().map { index, segment in
            ObservationMeasurement(
                spacingIn: segment.spacingIn,
                confidence: segment.confidence,
                label: index == 0 ? "left" : index == 1 ? "right" : "span_\(index + 1)"
            )
        }
    }

    private func selectedPrimarySegment(from segments: [LumberMeasurementSegment]) -> LumberMeasurementSegment? {
        segments.max { lhs, rhs in
            let lhsPreview = StudSpacingPreview(measuredInches: lhs.spacingIn)
            let rhsPreview = StudSpacingPreview(measuredInches: rhs.spacingIn)

            if lhsPreview.inspectionPriority == rhsPreview.inspectionPriority {
                return lhs.confidence < rhs.confidence
            }

            return lhsPreview.inspectionPriority < rhsPreview.inspectionPriority
        }
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
        closeInspection()
    }

    private func resumeScanning() {
        withAnimation(.easeInOut(duration: 0.25)) {
            verdict = nil
        }
    }

    private func closeInspection() {
        Task { await voice.disconnect() }
        dismiss()
    }

    @MainActor
    private func connectVoice() async {
        if let url = URL(string: appModel.backendBaseURL) {
            voice.backendBaseURL = url
        }
        await voice.connect()
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

    private func inspectionCheck(observationID: String, verdict: Verdict) -> ObservationInspectionCheck {
        ObservationInspectionCheck(
            observationID: observationID,
            verdict: verdict.status.rawValue,
            spans: verdict.spans.map {
                ObservationInspectionSpan(
                    label: $0.label.lowercased(),
                    spacingIn: $0.spacingIn,
                    verdict: $0.passes ? "pass" : "recheck",
                    confidence: $0.confidence
                )
            }
        )
    }
}

// MARK: - Agent voice indicator (bound to the live LiveKit session)

/// Hands-free agent indicator: shows the agent's live state, its latest spoken
/// line, and a mute toggle. The mic is managed automatically (open to hear the
/// wake word, closed while the agent speaks) — the button is just a manual mute.
struct AgentVoiceIndicator: View {
    let state: AgentVoiceState
    let transcript: String
    let muted: Bool
    let micActive: Bool
    let onToggleMute: () -> Void

    @State private var animate = false

    private var subtitle: String {
        if muted { return "Muted — tap the mic to talk back" }
        if !transcript.isEmpty { return transcript }
        switch state {
        case .offline: return "Reconnecting…"
        case .connecting: return "Bringing the inspector on the line…"
        case .listening: return "Just ask — “is this one okay?”"
        case .thinking: return "Looking up the local requirement…"
        case .speaking: return "…"
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
                    .lineLimit(2)
            }
            Spacer()
            Button(action: onToggleMute) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(muted ? .white : .black)
                    .frame(width: 36, height: 36)
                    .background(muted ? Color.white.opacity(0.16) : Theme.accent, in: Circle())
                    .overlay(
                        // Pulse ring when the mic is actually open and capturing.
                        Circle()
                            .stroke(Theme.accent.opacity(micActive && !muted ? 0.9 : 0), lineWidth: 2)
                            .scaleEffect(micActive && !muted ? 1.35 : 1)
                            .opacity(micActive && !muted ? 0 : 1)
                            .animation(micActive && !muted ? .easeOut(duration: 1).repeatForever(autoreverses: false) : .default, value: micActive)
                    )
            }
            .buttonStyle(.plain)
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
    let segments: [LumberMeasurementSegment]
    let minimumConfidence: Double
    let hasConfirmedMeasurement: Bool

    var body: some View {
        GeometryReader { geometry in
            let fallbackPair = selectedPair(in: geometry.size)

            ZStack(alignment: .topLeading) {
                ForEach(detections) { detection in
                    Rectangle()
                        .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .frame(width: max(detection.frame.width, 24), height: max(detection.frame.height, 24))
                    .position(detection.center)
                }

                if hasConfirmedMeasurement {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let preview = StudSpacingPreview(measuredInches: segment.spacingIn)
                        let color: Color = preview.passesWithTolerance ? Theme.accent : .red

                        Path { path in
                            path.move(to: segment.left)
                            path.addLine(to: segment.right)
                        }
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))

                        guidePoint(at: segment.left, color: color)
                        guidePoint(at: segment.right, color: color)

                        VStack(spacing: 1) {
                            Text(String(format: "%.2f in", segment.spacingIn))
                                .font(.system(size: 13, weight: .bold))
                                .monospacedDigit()
                            Text(preview.passesWithTolerance ? "Pass" : "Recheck")
                                .font(.system(size: 10, weight: .heavy))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(color, in: Capsule())
                            .position(
                                x: (segment.left.x + segment.right.x) / 2,
                                y: max(18, min(segment.left.y, segment.right.y) - 30)
                            )
                    }

                    if segments.isEmpty, let fallbackPair {
                        let preview = StudSpacingPreview(measuredInches: spacingIn)
                        let color: Color = preview.passesWithTolerance ? Theme.accent : .red

                        VStack(spacing: 1) {
                            Text(String(format: "%.2f in", spacingIn))
                                .font(.system(size: 13, weight: .bold))
                                .monospacedDigit()
                            Text(preview.passesWithTolerance ? "Pass" : "Recheck")
                                .font(.system(size: 10, weight: .heavy))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(color, in: Capsule())
                            .position(x: (fallbackPair.left.x + fallbackPair.right.x) / 2, y: fallbackPair.left.y - 30)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func guidePoint(at point: CGPoint, color: Color) -> some View {
        ZStack {
            Circle().stroke(color, lineWidth: 3).frame(width: 34, height: 34)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .position(point)
    }

    private func adjacentPairs(in size: CGSize) -> [(left: CGPoint, right: CGPoint)] {
        let bounds = CGRect(origin: .zero, size: size)
        let sorted = detections
            .filter { $0.confidence >= minimumConfidence && bounds.contains($0.center) }
            .sorted { $0.frame.midX < $1.frame.midX }
        guard sorted.count >= 2 else { return [] }

        return zip(sorted, sorted.dropFirst()).map { ($0.center, $1.center) }
    }

    private func selectedPair(in size: CGSize) -> (left: CGPoint, right: CGPoint)? {
        let pairs = adjacentPairs(in: size)
        guard !pairs.isEmpty else { return nil }

        let closestPair = pairs.min { lhs, rhs in
            abs(lhs.right.x - lhs.left.x) < abs(rhs.right.x - rhs.left.x)
        }
        guard let closestPair else { return nil }

        return closestPair
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
