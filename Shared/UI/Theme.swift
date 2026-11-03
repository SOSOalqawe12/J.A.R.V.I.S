import SwiftUI
#if os(iOS)
import UIKit
#endif

enum Theme {
    static let background = Color(red: 0.02, green: 0.05, blue: 0.09)
    static let panel = Color(red: 0.05, green: 0.10, blue: 0.16)
    static let panelHighlight = Color(red: 0.08, green: 0.16, blue: 0.24)
    static let accent = Color(red: 0.24, green: 0.88, blue: 1.0)
    static let accentDim = Color(red: 0.12, green: 0.45, blue: 0.56)
    static let warm = Color(red: 1.0, green: 0.68, blue: 0.24)
    static let text = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let userBubble = LinearGradient(
        colors: [Color(red: 0.07, green: 0.42, blue: 0.62), Color(red: 0.05, green: 0.30, blue: 0.48)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static var backgroundGradient: some View {
        ZStack {
            background
            RadialGradient(colors: [accent.opacity(0.12), .clear], center: .top, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct HUDPanel: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.panel.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.accent.opacity(0.22), lineWidth: 1)
            )
    }
}

extension View {
    func hudPanel(cornerRadius: CGFloat = 16) -> some View { modifier(HUDPanel(cornerRadius: cornerRadius)) }
}

@MainActor
enum Haptics {
    static func tap() {
        #if os(iOS)
        guard AppSettings.shared.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func success() {
        #if os(iOS)
        guard AppSettings.shared.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func error() {
        #if os(iOS)
        guard AppSettings.shared.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

/// The animated "core" orb: idle glow, spins while thinking, pulses with the voice.
struct CoreOrbView: View {
    enum Mode { case idle, thinking, listening, speaking }

    var mode: Mode = .idle
    var level: CGFloat = 0
    var size: CGFloat = 120

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed: Double = mode == .thinking ? 2.4 : (mode == .idle ? 0.35 : 1.0)
            let pulse = mode == .listening || mode == .speaking
                ? 1 + 0.12 * CGFloat(sin(t * 6)) * (0.4 + level)
                : 1 + 0.03 * CGFloat(sin(t * 1.5))
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.05), .clear],
                                         center: .center, startRadius: 2, endRadius: size * 0.6))
                    .scaleEffect(pulse * 1.1)
                ring(trim: 0.72, width: size * 0.035, scale: 0.92, angle: t * 60 * speed, opacity: 0.9)
                ring(trim: 0.45, width: size * 0.02, scale: 0.76, angle: -t * 90 * speed, opacity: 0.7)
                ring(trim: 0.86, width: size * 0.012, scale: 0.6, angle: t * 140 * speed, opacity: 0.55)
                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent.opacity(0.75))
                        .frame(width: size * 0.018, height: size * 0.07)
                        .offset(y: -size * 0.44)
                        .rotationEffect(.degrees(Double(index) * 30 + t * 20 * speed))
                }
                Circle()
                    .fill(RadialGradient(colors: [.white, Theme.accent, Theme.accentDim.opacity(0.4)],
                                         center: .center, startRadius: 0, endRadius: size * 0.2))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .scaleEffect(pulse)
                    .shadow(color: Theme.accent, radius: size * 0.12)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("JARVIS status")
    }

    private func ring(trim: CGFloat, width: CGFloat, scale: CGFloat, angle: Double, opacity: Double) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(Theme.accent.opacity(opacity), style: StrokeStyle(lineWidth: width, lineCap: .round))
            .frame(width: size * scale, height: size * scale)
            .rotationEffect(.degrees(angle))
    }
}
