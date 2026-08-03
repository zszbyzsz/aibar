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
                        phaseMarker
                        Text(L.activityTitle(lang, title: activity.displayTitle))
                            .font(.system(size: 11.5, weight: .bold))
                            .lineLimit(1)
                            .help(activity.displayTitle)
                        Spacer(minLength: 8)
                        ProgressView()
                            .controlSize(.small)
                        Text(L.activityAge(
                            lang,
                            seconds: Int(context.date.timeIntervalSince(activity.startedAt)),
                            scope: activity.timingScope
                        ))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Color.notchMutedInk)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(activityAccent.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(activityAccent.opacity(0.35), lineWidth: 1))

                    HStack(spacing: 7) {
                        phaseChip
                        if let model = activity.model, !model.isEmpty {
                            activityChip(icon: "cpu", text: model)
                        }
                        activityChip(
                            icon: "cube",
                            text: "\(Formatting.contextTokenLabel(activity.currentContextTokens)) / \(Formatting.contextTokenLabel(activity.conversationTokens))"
                        )
                        if !activity.sandboxPolicy.isEmpty {
                            activityChip(icon: "lock.shield", text: activity.sandboxPolicy)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L.activityAccessibilityLabel(
                    lang,
                    title: activity.displayTitle,
                    project: activity.project,
                    phase: activity.phase
                ))
            }
        }
    }

    private func isActive(at date: Date) -> Bool {
        date.timeIntervalSince(activity.lastActivityAt) <= CodexActivityMonitor.activeWindow
    }

    @ViewBuilder
    private var phaseMarker: some View {
        switch activity.phase {
        case .usingScreen:
            CodexScreenToolBadge(size: 21)
        default:
            Circle()
                .fill(Color.notchAccent)
                .frame(width: 7, height: 7)
                .shadow(color: Color.notchAccent.opacity(0.8), radius: 4)
            CodexActivityPhaseIcon(phase: activity.phase, size: 11)
        }
    }

    @ViewBuilder
    private var phaseChip: some View {
        switch activity.phase {
        case .usingScreen:
            HStack(spacing: 5) {
                CodexActivityPhaseIcon(phase: activity.phase, size: 11)
                Text(L.activityPhase(lang, phase: activity.phase))
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Color.notchScreenAccent)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.notchScreenAccent.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Color.notchScreenAccent.opacity(0.42), lineWidth: 1))
        default:
            activityChip(
                icon: standardPhaseIcon,
                text: L.activityPhase(lang, phase: activity.phase)
            )
        }
    }

    private var activityAccent: Color {
        switch activity.phase {
        case .usingScreen: return .notchScreenAccent
        default: return .notchAccent
        }
    }

    private var standardPhaseIcon: String {
        switch activity.phase {
        case .working: return "sparkles"
        case .thinking: return "brain.head.profile"
        case .usingTool: return "wrench.and.screwdriver"
        case .usingScreen: return "macwindow"
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
