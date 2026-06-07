import Foundation
import Observation

/// App-wide state: the active job site, the agent endpoint, and the inspection
/// history. Injected via `.environment` and shared across the navigation stack.
@MainActor
@Observable
final class AppModel {
    var jobSite: JobSite
    var recentSites: [JobSite]
    var records: [InspectionRecord] = []
    var agentEndpoint = "http://127.0.0.1:8000/events"

    private var observationCounter = 1

    init() {
        let sites = [
            JobSite(name: "Mission St Remodel", city: "San Francisco", state: "CA"),
            JobSite(name: "Capitol Hill ADU", city: "Seattle", state: "WA"),
            JobSite(name: "Pearl District Loft", city: "Portland", state: "OR"),
        ]
        recentSites = sites
        jobSite = sites[0]
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
