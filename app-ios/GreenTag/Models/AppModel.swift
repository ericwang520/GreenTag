import Foundation
import Observation

/// App-wide state: the active job site, the agent endpoint, and the inspection
/// history. Injected via `.environment` and shared across the navigation stack.
@MainActor
@Observable
final class AppModel {
    private static let conversationIDKey = "greentag.livekit.conversationID"

    var jobSite: JobSite
    var recentSites: [JobSite]
    var records: [InspectionRecord] = []
    var conversationID: String

    /// Backend base URL hosting `/connection-details` (the LiveKit token + agent
    /// dispatch). On a device, point this at the Mac's LAN address.
    var backendBaseURL = "https://greentag-backend-production.up.railway.app"

    private var observationCounter = 1

    init() {
        let sites = [
            JobSite(name: "Mission St Remodel", city: "San Francisco", state: "CA"),
            JobSite(name: "Capitol Hill ADU", city: "Seattle", state: "WA"),
            JobSite(name: "Pearl District Loft", city: "Portland", state: "OR"),
        ]
        recentSites = sites
        jobSite = sites[0]
        conversationID = Self.loadOrCreateConversationID()
    }

    /// Sequential id used to dedup observations on the agent side.
    func nextObservationID() -> String {
        defer { observationCounter += 1 }
        return String(format: "obs_ios_%04d", observationCounter)
    }

    func add(_ record: InspectionRecord) {
        records.insert(record, at: 0)
    }

    func selectSite(_ site: JobSite) {
        jobSite = site
        if !recentSites.contains(site) {
            recentSites.insert(site, at: 0)
        }
    }

    private static func loadOrCreateConversationID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: conversationIDKey), !existing.isEmpty {
            return existing
        }

        let created = "greentag-ios-\(UUID().uuidString.lowercased())"
        defaults.set(created, forKey: conversationIDKey)
        return created
    }

    // Session summary for the home dashboard.
    var passCount: Int { records.filter { $0.verdict.status == .pass }.count }
    var failCount: Int { records.filter { $0.verdict.status == .fail }.count }
    var reviewCount: Int { records.filter { $0.verdict.status == .review }.count }

    var passRateText: String {
        guard !records.isEmpty else { return "—" }
        let rate = Double(passCount) / Double(records.count)
        return "\(Int((rate * 100).rounded()))%"
    }
}
