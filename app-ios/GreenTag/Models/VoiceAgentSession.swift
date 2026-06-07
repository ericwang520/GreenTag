import Foundation
import LiveKit
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

    private let room = Room()
    private var agentIdentity: Participant.Identity?

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
            let details = try await fetchConnectionDetails(roomName: roomName)
            try await room.connect(url: details.serverUrl, token: details.participantToken)
            try await room.localParticipant.setMicrophone(enabled: true)
            isMicEnabled = true
            phase = .connected
        } catch {
            phase = .failed(error.localizedDescription)
            agentState = .offline
        }
    }

    func disconnect() async {
        await room.disconnect()
        isMicEnabled = false
        agentState = .offline
        agentTranscript = ""
        agentIdentity = nil
        phase = .idle
    }

    func toggleMicrophone() async {
        let target = !isMicEnabled
        do {
            try await room.localParticipant.setMicrophone(enabled: target)
            isMicEnabled = target
        } catch {
            // keep the previous state on failure
        }
    }

    // MARK: - Send an observation over the data channel

    func send(_ observation: FieldObservation) async {
        guard phase == .connected else { return }
        guard let data = try? JSONEncoder().encode(observation) else { return }
        let options = DataPublishOptions(topic: Self.observationTopic, reliable: true)
        try? await room.localParticipant.publish(data: data, options: options)
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
