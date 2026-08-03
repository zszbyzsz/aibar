import SwiftUI

/// Shared phase marker used by both the dashboard activity card and the
/// always-on capsule. Screen control gets a composed icon instead of another
/// generic tool glyph so it remains recognizable in the compact capsule.
struct CodexActivityPhaseIcon: View {
    let phase: ProjectActivity.Phase
    var size: CGFloat = 11

    var body: some View {
        switch phase {
        case .usingScreen:
            CodexScreenToolBadge(size: size)
        default:
            Image(systemName: systemImageName)
                .font(.system(size: size, weight: .semibold))
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
    @State private var isBright = false

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
                            Color.notchScreenAccent.opacity(isBright ? 0.92 : 0.52),
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
                .offset(x: size * 0.14, y: size * 0.14)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.notchScreenAccent.opacity(isBright ? 0.55 : 0.28), radius: 5)
        .scaleEffect(isBright ? 1.04 : 0.96)
        .opacity(isBright ? 1 : 0.82)
        .onAppear {
            guard animate else {
                isBright = true
                return
            }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                isBright = true
            }
        }
    }
}
