import SwiftUI

/// Shared visual language: a dark, high-contrast field palette with a green
/// accent — legible outdoors and forgiving of gloved taps.
enum Theme {
    static let background = Color(red: 0.04, green: 0.06, blue: 0.05)
    static let surface = Color.white.opacity(0.06)
    static let surfaceStrong = Color.white.opacity(0.10)
    static let stroke = Color.white.opacity(0.12)

    static let accent = Color.green
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.68)
    static let textTertiary = Color.white.opacity(0.5)

    static func color(for status: VerdictStatus) -> Color {
        switch status {
        case .pass: .green
        case .review: .orange
        case .fail: .red
        case .pending: .cyan
        }
    }
}

/// Card container used across home and inspection screens.
private struct CardBackground: ViewModifier {
    var padding: CGFloat
    var cornerRadius: CGFloat
    var strong: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                strong ? Theme.surfaceStrong : Theme.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = 18, strong: Bool = false) -> some View {
        modifier(CardBackground(padding: padding, cornerRadius: cornerRadius, strong: strong))
    }
}

/// Status pill (PASS / NEEDS REVIEW / FAIL) reused in history rows and cards.
struct StatusPill: View {
    let status: VerdictStatus
    var compact: Bool = false

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.system(size: compact ? 11 : 13, weight: .bold))
            .foregroundStyle(Theme.color(for: status))
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 5 : 7)
            .background(Theme.color(for: status).opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(Theme.color(for: status).opacity(0.4), lineWidth: 1))
    }
}
