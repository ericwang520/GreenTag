import SwiftUI

/// Entry screen. Pick the job site, launch an AR inspection, and review the
/// history of checks done this session.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    @State private var isInspecting = false
    @State private var selectedRecord: InspectionRecord?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    jobSiteCard
                    startButton
                    if !appModel.records.isEmpty {
                        sessionSummary
                    }
                    historySection
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $isInspecting) {
            InspectionView()
                .environment(appModel)
        }
        .sheet(item: $selectedRecord) { record in
            RecordDetailSheet(record: record)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.background)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("GreenTag", systemImage: "viewfinder")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Theme.accent)

            Text("Catch framing violations before the official inspection.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: Job site

    private var jobSiteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("JOB SITE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(appModel.jobSite.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)

                    Text(appModel.jobSite.locationLine)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Menu {
                    ForEach(appModel.recentSites) { site in
                        Button {
                            appModel.selectSite(site)
                        } label: {
                            Label("\(site.name) · \(site.locationLine)", systemImage: "mappin")
                        }
                    }
                } label: {
                    Text("Change")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }
            }

            Text("Code is retrieved for this jurisdiction during the check.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .card()
    }

    // MARK: Start

    private var startButton: some View {
        Button {
            isInspecting = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start AR inspection")
                        .font(.system(size: 18, weight: .heavy))
                    Text("Point at the framing — voice walks you through it")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.7))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Session summary

    private var sessionSummary: some View {
        HStack(spacing: 12) {
            summaryStat(value: appModel.passRateText, label: "Pass rate", color: Theme.accent)
            summaryStat(value: "\(appModel.passCount)", label: "Passed", color: .green)
            summaryStat(value: "\(appModel.reviewCount)", label: "Review", color: .orange)
            summaryStat(value: "\(appModel.failCount)", label: "Failed", color: .red)
        }
    }

    private func summaryStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 12, cornerRadius: 14)
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !appModel.records.isEmpty {
                    Text("\(appModel.records.count) check\(appModel.records.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if appModel.records.isEmpty {
                emptyHistory
            } else {
                VStack(spacing: 10) {
                    ForEach(appModel.records) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            HistoryRow(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("No checks yet")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            Text("Run your first AR inspection to start the report.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .card()
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let record: InspectionRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.kind.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.color(for: record.verdict.status))
                .frame(width: 42, height: 42)
                .background(Theme.color(for: record.verdict.status).opacity(0.14), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.kind.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(String(format: "%.2f in", record.verdict.spacingIn)) · \(record.site.city) · \(Self.time(record.createdAt))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            StatusPill(status: record.verdict.status, compact: true)
        }
        .card(padding: 12, cornerRadius: 14)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Record detail sheet

private struct RecordDetailSheet: View {
    let record: InspectionRecord

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VerdictCard(verdict: record.verdict, site: record.site, showsActions: false)
            }
            .padding(20)
        }
        .background(Theme.background)
    }
}

#Preview {
    HomeView()
        .environment(AppModel())
}
