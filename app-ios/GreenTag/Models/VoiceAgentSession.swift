import Foundation
import LiveKit
import AVFoundation
import SwiftUI

/// The conversational agent's live state, surfaced in the inspection HUD.
enum AgentVoiceState {
    case offline
    case connecting
    case listening
    case thinking
    case speaking

    var title: String {
        switch self {
        case .offline: "Inspector offline"
        case .connecting: "Connecting to inspector…"
        case .listening: "Listening"
        case .thinking: "Checking the code…"
        case .speaking: "Inspector speaking"
        }
    }

    var color: Color {
        switch self {
        case .offline: .gray
        case .connecting: .cyan
        case .listening: .cyan
        case .thinking: .orange
        case .speaking: .green
        }
    }

    var isAnimating: Bool {
        switch self {
        case .connecting, .thinking, .speaking: true
        case .offline, .listening: false
        }
    }
}

/// Live voice link to the GreenTag agent over LiveKit.
///
/// Flow: fetch a token from the backend `/connection-details` (which dispatches
/// the named agent into the room), connect, publish the mic, and observe the
/// agent's state + transcript. Field observations are sent over the room's data
/// channel (topic `field_observation`) — the agent announces the verdict by
/// voice, so no LAN IP / per-session HTTP port is needed.
@MainActor
final class VoiceAgentSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    static let observationTopic = "field_observation"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var agentState: AgentVoiceState = .offline
    @Published private(set) var agentTranscript: String = ""
    @Published private(set) var isMicEnabled = false
    /// User-controlled mute. When true the mic stays closed regardless of the
    /// auto half-duplex logic.
    @Published var muted = false

    private let room = Room()
    private var agentIdentity: Participant.Identity?

    /// Latest desired mic state, recomputed by `reconcileMic`. A single drain
    /// task (below) walks the room mic toward this value; serializing through it
    /// avoids overlapping `setMicrophone` calls racing across their awaits.
    private var desiredMic = false
    private var micDraining = false

    /// Backend base URL hosting `/connection-details`, e.g. http://127.0.0.1:8000
    var backendBaseURL: URL

    init(backendBaseURL: URL) {
        self.backendBaseURL = backendBaseURL
        room.add(delegate: self)
    }

    var isConnected: Bool { phase == .connected }

    // MARK: - Connect / disconnect

    func connect(roomName: String? = nil) async {
        guard phase != .connected, phase != .connecting else { return }
        phase = .connecting
        agentState = .connecting
        do {
            configureAudioForVoice()
            let details = try await fetchConnectionDetails(roomName: roomName)
            print("[GreenTag LiveKit] connecting room=\(details.roomName) participant=\(details.participantName)")
            try await room.connect(url: details.serverUrl, token: details.participantToken)
            phase = .connected
            // Hands-free: open the mic so the agent can hear the wake word. The
            // half-duplex rule below then closes it whenever the agent is
            // speaking, which kills the speaker→mic echo loop.
            reconcileMic()
        } catch {
            phase = .failed(error.localizedDescription)
            agentState = .offline
        }
    }

    func disconnect() async {
        await room.disconnect()
        isMicEnabled = false
        desiredMic = false
        agentState = .offline
        agentTranscript = ""
        agentIdentity = nil
        phase = .idle
    }

    /// User toggles their own mute. Auto half-duplex still applies on top.
    func toggleMute() {
        muted.toggle()
        reconcileMic()
    }

    /// Desired mic state for hands-free half-duplex: open while connected and
    /// unmuted, but closed whenever the agent is speaking (so its voice from the
    /// speaker doesn't loop back into the mic). Called on connect and on every
    /// agent-state change.
    private func reconcileMic() {
        desiredMic = phase == .connected && !muted && agentState != .speaking
        // Only one drain runs at a time; a concurrent reconcile just updates
        // `desiredMic` and the in-flight drain picks it up on its next pass.
        guard !micDraining else { return }
        micDraining = true
        Task { await drainMic() }
    }

    /// Walk the room mic toward `desiredMic`, re-reading it after every call so a
    /// state flip mid-await is corrected on the next pass. The exit check and the
    /// `micDraining = false` write run without an await between them (MainActor is
    /// single-threaded), so a reconcile can't slip in and be lost.
    private func drainMic() async {
        while phase == .connected, isMicEnabled != desiredMic {
            let target = desiredMic
            do {
                try await room.localParticipant.setMicrophone(enabled: target)
                isMicEnabled = target
            } catch {
                break  // keep previous state on failure; next reconcile retries
            }
        }
        micDraining = false
    }

    /// Keep the physical iPhone in a stable voice-chat route. Without an
    /// explicit category, real devices can flip between receiver/speaker
    /// behavior as LiveKit enables and disables capture for half-duplex.
    private func configureAudioForVoice() {
        #if os(iOS)
        let options: AVAudioSession.CategoryOptions = [
            .defaultToSpeaker,
            .allowBluetoothHFP,
            .allowBluetoothA2DP,
            .mixWithOthers,
        ]

        AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = false
        AudioManager.shared.isSpeakerOutputPreferred = true
        AudioManager.shared.customConfigureAudioSessionFunc = { _, _ in
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try? session.setActive(true)
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setActive(true)
        #endif
    }

    // MARK: - Send an observation over the data channel

    func send(_ observation: FieldObservation) async {
        guard phase == .connected else {
            print("[GreenTag LiveKit] skip observation \(observation.observationID): room not connected, phase=\(phase)")
            return
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(observation)
        } catch {
            print("[GreenTag LiveKit] encode failed for observation \(observation.observationID): \(error)")
            return
        }

        let options = DataPublishOptions(topic: Self.observationTopic, reliable: true)
        print(
            "[GreenTag LiveKit] sending observation \(observation.observationID) " +
            "topic=\(Self.observationTopic) announce=\(observation.announce) " +
            "spacing=\(String(format: "%.2f", observation.measurement.spacingIn))in " +
            "confidence=\(Int((observation.measurement.confidence * 100).rounded()))% " +
            "spans=\(observation.measurements.count) bytes=\(data.count)"
        )

        do {
            try await room.localParticipant.publish(data: data, options: options)
            print("[GreenTag LiveKit] sent observation \(observation.observationID)")
        } catch {
            print("[GreenTag LiveKit] publish failed for observation \(observation.observationID): \(error)")
        }
    }

    /// Throttle state for the continuous live stream (below).
    private var lastStreamSpacing: Double?
    private var lastStreamAt = Date.distantPast

    /// Continuously feed the agent the live reading so its get_current_reading
    /// tool is always fresh — without a button tap. Throttled so we don't flood
    /// the data channel: send only on a meaningful spacing change or every ~1.5s.
    /// `observation` must carry announce=false so the agent updates state silently
    /// (no spoken narration on every frame); the explicit lock tap sends
    /// announce=true to trigger the proactive verdict.
    func streamReading(_ observation: FieldObservation, spacingIn: Double) async {
        guard phase == .connected else { return }
        let now = Date()
        // Keep the agent's reading close to what's on screen: push on any small
        // change or at least twice a second, so get_current_reading is never stale.
        let movedEnough = lastStreamSpacing.map { abs($0 - spacingIn) >= 0.1 } ?? true
        let dueByTime = now.timeIntervalSince(lastStreamAt) >= 0.5
        guard movedEnough || dueByTime else { return }
        lastStreamSpacing = spacingIn
        lastStreamAt = now
        await send(observation)
    }

    // MARK: - Connection details

    private struct ConnectionDetails: Decodable {
        let serverUrl: String
        let roomName: String
        let participantName: String
        let participantToken: String
    }

    private func fetchConnectionDetails(roomName: String?) async throws -> ConnectionDetails {
        var components = URLComponents(
            url: backendBaseURL.appendingPathComponent("connection-details"),
            resolvingAgainstBaseURL: false
        )
        if let roomName {
            components?.queryItems = [URLQueryItem(name: "room", value: roomName)]
        }
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ConnectionDetails.self, from: data)
    }

    // MARK: - Agent state mapping

    fileprivate func applyAgentAttributes(_ attributes: [String: String], from identity: Participant.Identity) {
        guard let raw = attributes["lk.agent.state"] else { return }
        agentIdentity = identity
        agentState = Self.mapAgentState(raw)
        // Close the mic while the agent speaks, reopen when it stops.
        reconcileMic()
    }

    private static func mapAgentState(_ raw: String) -> AgentVoiceState {
        switch raw {
        case "listening": .listening
        case "thinking": .thinking
        case "speaking": .speaking
        default: .connecting
        }
    }

    fileprivate func appendAgentTranscript(_ segments: [TranscriptionSegment], from identity: Participant.Identity?) {
        // Only show the agent's speech, not the user's own STT.
        guard let identity, identity == agentIdentity else { return }
        if let latest = segments.last(where: { $0.isFinal }) ?? segments.last {
            agentTranscript = latest.text
        }
    }

    fileprivate func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .disconnected:
            phase = .idle
            agentState = .offline
        case .connecting, .reconnecting:
            phase = .connecting
            if agentState == .offline { agentState = .connecting }
        case .connected:
            phase = .connected
            reconcileMic()
        default:
            break
        }
    }
}

// MARK: - RoomDelegate (callbacks may arrive off the main actor)

extension VoiceAgentSession: RoomDelegate {
    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        Task { @MainActor in self.handleConnectionState(connectionState) }
    }

    nonisolated func room(
        _ room: Room,
        participant: Participant,
        didUpdateAttributes attributes: [String: String]
    ) {
        let identity = participant.identity
        Task { @MainActor in
            if let identity { self.applyAgentAttributes(attributes, from: identity) }
        }
    }

    nonisolated func room(
        _ room: Room,
        participant: Participant,
        trackPublication: TrackPublication,
        didReceiveTranscriptionSegments segments: [TranscriptionSegment]
    ) {
        let identity = participant.identity
        Task { @MainActor in self.appendAgentTranscript(segments, from: identity) }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let attributes = participant.attributes
        let identity = participant.identity
        Task { @MainActor in
            if let identity { self.applyAgentAttributes(attributes, from: identity) }
        }
    }
}
