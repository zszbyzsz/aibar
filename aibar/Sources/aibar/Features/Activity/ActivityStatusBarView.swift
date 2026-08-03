import AppKit
import SwiftUI

/// The SwiftUI presentation layer for the activity capsule stack. Keeping it
/// apart from `ActivityStatusBarController` makes the controller responsible
/// only for polling and panel lifecycle, while these views own interaction
/// and rendering details.
struct ActivityStatusBarView: View {
    @ObservedObject var controller: ActivityStatusBarController
    @Environment(\.appLanguage) private var lang

    var body: some View {
        // The top row is pulled out of the `ForEach` entirely and rendered
        // on its own, unconditionally (whenever there's anything to show at
        // all) — the current project a viewer is already looking at should
        // never itself be treated as "inserted" or animated just because
        // hovering changed how many rows are mounted below it. Only rows
        // *after* the first — the ones actually being revealed — sit in the
        // `ForEach` and only exist once `isExpanded` is true, so they alone
        // get the `.opacity` transition. `.notchSpring` in
        // `setListHovering(_:)` uses the exact same curve and duration as
        // the AppKit frame resize below, so the two move together instead
        // of visibly drifting apart.
        VStack(spacing: ActivityStatusBarController.rowSpacing) {
            if let topRow = controller.rows.first {
                CapsuleRowView(row: topRow, lang: lang, onTap: { controller.activate(topRow) })
            }
            if controller.isExpanded {
                ForEach(controller.rows.dropFirst()) { row in
                    CapsuleRowView(row: row, lang: lang, onTap: { controller.activate(row) })
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in controller.setListHovering(hovering) }
        .environment(\.appLanguage, AppLanguage.loadSaved())
    }
}

/// A single row's pill — either an in-progress project or a finished one's
/// outcome — plus the shared interaction chrome (press scale, hover shadow,
/// click-to-open-Codex) every row gets regardless of which content it holds.
private struct CapsuleRowView: View {
    let row: CapsuleRow
    let lang: AppLanguage
    let onTap: () -> Void
    @State private var isPressed = false
    @State private var isHighlighted = false
    /// Whether *this* row currently owns a push on the shared `NSCursor`
    /// stack — see `setCursorPushed(_:)`.
    @State private var didPushCursor = false

    var body: some View {
        content
            .foregroundStyle(Color.notchInk)
            .capsuleChrome(
                isHighlighted: isHighlighted,
                isPressed: isPressed,
                isUpdate: isUpdate,
                isScreenControl: isScreenControl
            )
            .frame(height: 32)
            .onTapGesture(perform: onTap)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.18)) { isHighlighted = hovering }
                setCursorPushed(hovering)
            }
            // Expanding and collapsing mounts and unmounts rows underneath a
            // stationary pointer, and a row torn down while hovered never
            // gets its own `onHover(false)` — so without this the push it
            // took out is never balanced by a pop.
            .onDisappear { setCursorPushed(false) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    /// `NSCursor`'s push/pop is a process-wide stack, not a per-view setting,
    /// so every push has to be matched exactly once. Guarding on the row's own
    /// state makes both directions idempotent: repeated hover callbacks (which
    /// SwiftUI does emit around a relayout) can't stack up duplicate pushes,
    /// and the `onDisappear` cleanup above can't pop a push this row never
    /// took. Left unbalanced, the stack only ever grows over a session, and
    /// the pointer keeps the pointing-hand shape well after leaving the pill.
    private func setCursorPushed(_ pushed: Bool) {
        guard pushed != didPushCursor else { return }
        didPushCursor = pushed
        if pushed {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    @ViewBuilder private var content: some View {
        switch row.display {
        case .active(let activity):
            ActivePillContent(activity: activity, lang: lang)
        case .completed(let project, let outcome):
            CompletedPillContent(project: project, outcome: outcome, lang: lang)
        case .completionSummary(let count):
            CompletionSummaryPillContent(count: count, lang: lang)
        case .update(let notice):
            UpdatePillContent(notice: notice, lang: lang)
        }
    }

    private var isUpdate: Bool {
        if case .update = row.display { return true }
        return false
    }

    private var isScreenControl: Bool {
        guard case .active(let activity) = row.display else { return false }
        return activity.phase == .usingScreen
    }

    private var accessibilityLabel: String {
        switch row.display {
        case .active(let activity):
            return L.activityAccessibilityLabel(
                lang,
                title: activity.displayTitle,
                project: activity.project,
                phase: activity.phase
            )
        case .completed(let project, let outcome):
            return L.activityCompletedAccessibilityLabel(lang, project: project, outcome: outcome)
        case .completionSummary(let count):
            return L.activityCompletionSummaryAccessibilityLabel(lang, count: count)
        case .update(let notice):
            return L.updateAccessibilityLabel(lang, version: notice.version, downloaded: notice.packageURL != nil)
        }
    }
}

private struct CompletionSummaryPillContent: View {
    var count: Int
    var lang: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.290, green: 0.960, blue: 0.580))
            Text(L.activityCompletionSummary(lang))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(L.activityCompletionSummaryAction(lang))
                .font(.system(size: 9.5))
                .foregroundStyle(Color.notchMutedInk)
        }
    }
}

private struct UpdatePillContent: View {
    var notice: AppUpdateNotice
    var lang: AppLanguage

    private let tint = Color(red: 1.000, green: 0.650, blue: 0.180)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: notice.packageURL == nil ? "arrow.down.circle.fill" : "shippingbox.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text("aibar")
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 4)
            Text(L.updateCapsuleLabel(lang, version: notice.version, downloaded: notice.packageURL != nil))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1)
        }
    }
}

/// The pill's content while a project is actively running — pulse dot, phase
/// icon, project name, live token count, and elapsed time.
private struct ActivePillContent: View {
    var activity: ProjectActivity
    var lang: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            phaseMarker
            Text(activity.displayTitle)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .help(activity.displayTitle)
            Spacer(minLength: 4)
            ContextTokenReadout(
                current: activity.currentContextTokens,
                total: activity.conversationTokens,
                lang: lang
            )
            Spacer(minLength: 4)
            TimelineView(.periodic(from: Self.tickAnchor, by: 1)) { context in
                HStack(spacing: 2) {
                    if activity.timingScope == .continuousGoal {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 7.5, weight: .semibold))
                    }
                    Text(Self.compactAge(context.date.timeIntervalSince(activity.startedAt)))
                        .font(.system(size: 9.5).monospacedDigit())
                }
                .foregroundStyle(Color.notchMutedInk)
            }
        }
    }

    @ViewBuilder
    private var phaseMarker: some View {
        switch activity.phase {
        case .usingScreen:
            // The composed window + cursor badge is intentionally a single
            // leading marker: unlike the ordinary pulse + phase pair, it
            // reads as a distinct "Codex is operating the screen" state.
            CodexScreenToolBadge(size: 20)
        default:
            ActivityPulseDot()
            CodexActivityPhaseIcon(phase: activity.phase, size: 10)
        }
    }

    /// One shared origin for every row's elapsed-time clock. Anchoring each
    /// row's schedule to its own `.now` meant a ten-row stack ticked at ten
    /// unrelated points in the second, so SwiftUI woke up and ran a render
    /// pass ten separate times per second instead of once. Rows created at
    /// any moment now land on the same boundaries and coalesce into a single
    /// update — the displayed second is identical either way.
    private static let tickAnchor = Date(timeIntervalSinceReferenceDate: 0)

    private static func compactAge(_ seconds: TimeInterval) -> String {
        let safeSeconds = max(0, Int(seconds))
        guard safeSeconds >= 60 else { return "\(safeSeconds)s" }
        let (hours, minutes) = Formatting.hoursAndMinutes(fromSeconds: safeSeconds)
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }
}

/// A finished project's content: outcome icon, project name, and outcome
/// word. Same size and weight as `ActivePillContent` — it's a full row in the
/// stack, not a lesser, secondary one.
private struct CompletedPillContent: View {
    var project: String
    var outcome: ActivityOutcome
    var lang: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(project)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text(L.activityOutcomeLabel(lang, outcome: outcome))
                .font(.system(size: 9.5))
                .foregroundStyle(Color.notchMutedInk)
        }
    }

    private var icon: String {
        switch outcome {
        case .completed: return "checkmark.circle.fill"
        case .aborted: return "xmark.circle.fill"
        case .timedOut: return "pause.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case .completed: return Color(red: 0.290, green: 0.960, blue: 0.580)
        case .aborted: return Color(red: 0.980, green: 0.400, blue: 0.400)
        case .timedOut: return Color.notchMutedInk
        }
    }
}

/// A compact, continuously-updating token count for the capsule's middle gap.
/// `contentTransition(.numericText())` is what actually sells "flowing" —
/// digits roll rather than snap — but that transition only exists on macOS
/// 14+, so it's applied conditionally rather than dropping support for the
/// package's macOS 13 floor.
private struct ContextTokenReadout: View {
    var current: Int
    var total: Int
    var lang: AppLanguage

    var body: some View {
        let currentLabel = Formatting.contextTokenLabel(current)
        let totalLabel = Formatting.contextTokenLabel(total)

        Group {
            if #available(macOS 14.0, *) {
                labels(current: currentLabel, total: totalLabel)
                    .contentTransition(.numericText())
            } else {
                labels(current: currentLabel, total: totalLabel)
            }
        }
        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
        .animation(.easeOut(duration: 0.3), value: current)
        .animation(.easeOut(duration: 0.3), value: total)
        .help(L.activityContextHint(lang))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L.activityContextAccessibility(lang, current: currentLabel, total: totalLabel)
        )
    }

    private func labels(current: String, total: String) -> some View {
        HStack(spacing: 2) {
            Text(current).foregroundStyle(Color.notchAccent)
            Text("/").foregroundStyle(Color.notchMutedInk)
            Text(total).foregroundStyle(Color.notchInk)
        }
    }
}

private extension View {
    /// Shared shell (padding, solid background, press scale, hover shadow)
    /// every row in the stack gets. The background stays solid black
    /// regardless of hover — unlike this pill's very first version, which
    /// turned transparent on hover to peek at whatever was underneath; that
    /// interaction is gone now that hovering instead pulls the rest of the
    /// stack down, and a capsule whose whole point is staying legible
    /// shouldn't then fade away the moment someone looks at it.
    ///
    /// Hover is marked with a hairline rim rather than the drop shadow this
    /// used to fade in. That shadow could never actually be seen: it applied
    /// to the row's *contents*, underneath the opaque black capsule drawn
    /// behind them, so it only ever darkened black against black — while
    /// still forcing a real offscreen blur pass on the exact frames the
    /// expand animation was already competing for. A stroke is drawn as plain
    /// vector geometry, costs nothing comparable, and unlike the shadow it's
    /// visible (an outward shadow would in any case be clipped away, since the
    /// panel is sized to the capsule itself with nothing to spill into).
    func capsuleChrome(
        isHighlighted: Bool,
        isPressed: Bool,
        isUpdate: Bool,
        isScreenControl: Bool
    ) -> some View {
        self
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Capsule()
                    .fill(
                        isUpdate
                            ? Color(red: 0.125, green: 0.082, blue: 0.025)
                            : isScreenControl
                                ? Color(red: 0.095, green: 0.062, blue: 0.145)
                                : Color.black
                    )
                    .overlay {
                        Capsule().strokeBorder(
                            isUpdate
                                ? Color(red: 1.000, green: 0.650, blue: 0.180)
                                    .opacity(isHighlighted ? 0.65 : 0.32)
                                : isScreenControl
                                    ? Color.notchScreenAccent.opacity(isHighlighted ? 0.82 : 0.48)
                                : Color.white.opacity(isHighlighted ? 0.20 : 0),
                            lineWidth: 1
                        )
                    }
            }
            .contentShape(Capsule())
            .scaleEffect(isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
    }
}

/// The "still running" heartbeat on every active row.
///
/// The glow is a *fixed* radius, with only opacity and scale breathing. An
/// earlier version animated the shadow's radius instead, which looks the same
/// but costs enormously more: a blur radius that changes every frame can't be
/// cached, so each dot re-rasterized its glow offscreen ~60 times a second —
/// and the whole point of the expanded stack is that ten of these are on
/// screen at once, all animating forever. Opacity and scale are composited
/// from an already-rasterized layer, so the same breathing read is effectively
/// free no matter how many rows are showing.
private struct ActivityPulseDot: View {
    @State private var isBright = false

    var body: some View {
        Circle()
            .fill(Color.notchAccent)
            .frame(width: 6, height: 6)
            .shadow(color: Color.notchAccent.opacity(0.75), radius: 3)
            .opacity(isBright ? 1 : 0.5)
            .scaleEffect(isBright ? 1 : 0.8)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isBright = true
                }
            }
    }
}
