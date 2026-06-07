import SwiftUI

/// The compliance result, as the agent would announce it: verdict, the measured
/// value vs. the layout, and the cited code clause. Reused in the inspection
/// overlay (with actions) and the history detail sheet (read-only).
struct VerdictCard: View {
    let verdict: Verdict
    let site: JobSite
    var showsActions: Bool = true
    var onSave: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil

    private var color: Color { Theme.color(for: verdict.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            measurementRow
            Divider().background(Theme.stroke)
            clauseBlock
            if verdict.isPreview {
                previewNote
            }
            if showsActions {
                actions
            }
        }
        .padding(20)
        .background(Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(color.opacity(0.45), lineWidth: 1.5)
        )
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: verdict.status.systemImage)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(verdict.status.title)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(color)
                Text(verdict.headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var measurementRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Measured")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(String(format: "%.2f in", verdict.spacingIn))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(verdict.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Confidence")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(Int((verdict.confidence * 100).rounded()))%")
                    .font(.system(size: 24, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var clauseBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(verdict.citation)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(site.city)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(verdict.clause)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var previewNote: some View {
        Label(
            "On-device preview. The agent confirms the official ruling by voice.",
            systemImage: "waveform"
        )
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                onContinue?()
            } label: {
                Text("Keep scanning")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                onSave?()
            } label: {
                Label("Save to report", systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        VerdictCard(
            verdict: FramingCodePreview.verdict(spacingIn: 15.25, confidence: 0.86),
            site: JobSite(name: "Mission St Remodel", city: "San Francisco", state: "CA")
        )
        .padding(20)
    }
}
