import SwiftUI

/// Shared phase marker used by both the dashboard activity card and the
/// always-on capsule. Screen control gets a composed icon instead of another
/// generic tool glyph so it remains recognizable in the compact capsule.
struct CodexActivityPhaseIcon: View {
    let phase: ProjectActivity.Phase
    var size: CGFloat = 11
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationPhase = false

    var body: some View {
        switch phase {
        case .usingScreen:
            CodexScreenToolBadge(size: size, animate: animate)
        default:
            Image(systemName: systemImageName)
                .font(.system(size: size, weight: .semibold))
                .rotationEffect(.degrees(iconRotation))
                .offset(iconOffset)
                .scaleEffect(iconScale)
                .onAppear(perform: startAnimation)
        }
    }

    private var iconRotation: Double {
        guard animate, !reduceMotion else { return 0 }
        switch phase {
        case .working: return animationPhase ? 8 : -8
        case .thinking: return animationPhase ? 2 : -2
        case .usingTool: return animationPhase ? 7 : -7
        case .editing: return animationPhase ? -5 : 5
        case .usingScreen: return 0
        }
    }

    private var iconOffset: CGSize {
        guard animate, !reduceMotion else { return .zero }
        switch phase {
        case .thinking:
            return CGSize(width: 0, height: animationPhase ? -0.7 : 0.7)
        case .editing:
            return CGSize(width: animationPhase ? 0.8 : -0.8, height: 0)
        default:
            return .zero
        }
    }

    private var iconScale: CGFloat {
        guard animate, !reduceMotion else { return 1 }
        switch phase {
        case .working: return animationPhase ? 1.06 : 0.94
        case .thinking: return animationPhase ? 1.03 : 0.97
        default: return 1
        }
    }

    private func startAnimation() {
        guard animate, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: animationDuration).repeatForever(autoreverses: true)) {
            animationPhase = true
        }
    }

    private var animationDuration: TimeInterval {
        switch phase {
        case .thinking: return 1.1
        case .editing: return 0.7
        default: return 0.85
        }
    }

    private var systemImageName: String {
        switch phase {
        case .working: return "sparkles"
        case .thinking: return "brain.head.profile"
        case .usingTool: return "wrench.and.screwdriver"
        case .usingScreen: return "macwindow"
        case .editing: return "pencil.line"
        }
    }
}

/// A small, animated screen-control badge: a window plus a cursor. The violet
/// accent is reserved for this phase so it cannot be confused with ordinary
/// tool use or file editing.
struct CodexScreenToolBadge: View {
    var size: CGFloat = 20
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorAdvanced = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: max(4, size * 0.24))
                .fill(
                    LinearGradient(
                        colors: [
                            Color.notchScreenAccent.opacity(0.25),
                            Color.notchAccent.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: max(4, size * 0.24))
                        .strokeBorder(
                            Color.notchScreenAccent.opacity(0.72),
                            lineWidth: 1
                        )
                }

            Image(systemName: "macwindow")
                .font(.system(size: size * 0.54, weight: .semibold))
                .foregroundStyle(Color.notchScreenAccent)
                .offset(x: -size * 0.02, y: -size * 0.02)

            Image(systemName: "cursorarrow")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.65), radius: 1, y: 1)
                .offset(
                    x: size * (cursorAdvanced ? 0.06 : 0.16),
                    y: size * (cursorAdvanced ? 0.04 : 0.16)
                )
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animate, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                cursorAdvanced = true
            }
        }
    }
}
