import SwiftUI

/// A transient, local-only monitor shown below the projects card. It disappears
/// after `CodexActivityMonitor.activeWindow` without an index update, keeping
/// the dashboard quiet whenever Codex is idle.
struct ProjectActivityMonitorView: View {
    var activity: ProjectActivity
    @Environment(\.appLanguage) private var lang

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if isActive(at: context.date) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.notchAccent)
                            .frame(width: 7, height: 7)
                            .shadow(color: Color.notchAccent.opacity(0.8), radius: 4)
                        Image(systemName: phaseIcon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(L.activityTitle(lang, project: activity.project))
                            .font(.system(size: 11.5, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        ProgressView()
                            .controlSize(.small)
                        Text(L.activityAge(lang, seconds: Int(context.date.timeIntervalSince(activity.startedAt))))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Color.notchMutedInk)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.notchAccent.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.notchAccent.opacity(0.35), lineWidth: 1))

                    HStack(spacing: 7) {
                        activityChip(icon: phaseIcon, text: L.activityPhase(lang, phase: activity.phase))
                        if let model = activity.model, !model.isEmpty {
                            activityChip(icon: "cpu", text: model)
                        }
                        activityChip(icon: "cube", text: L.activityTokens(lang, tokens: Formatting.tokenLabel(activity.sessionTokens)))
                        if !activity.sandboxPolicy.isEmpty {
                            activityChip(icon: "lock.shield", text: activity.sandboxPolicy)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L.activityAccessibilityLabel(lang, project: activity.project, phase: activity.phase))
            }
        }
    }

    private func isActive(at date: Date) -> Bool {
        date.timeIntervalSince(activity.lastActivityAt) <= CodexActivityMonitor.activeWindow
    }

    private var phaseIcon: String {
        switch activity.phase {
        case .working: return "sparkles"
        case .thinking: return "brain.head.profile"
        case .usingTool: return "wrench.and.screwdriver"
        case .editing: return "pencil.line"
        }
    }

    private func activityChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Color.notchMutedInk)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.notchTrack))
    }
}
