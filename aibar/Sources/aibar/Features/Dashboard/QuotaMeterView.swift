import SwiftUI

/// The label/window-hint are shown by the enclosing SectionCard's header, so this
/// view only owns the meter itself. A ring gauge with the percentage set in a
/// large rounded numeral reads as an instrument dial rather than a flat progress
/// bar — the point of the redesign was to make this feel like a crafted readout,
/// not just another stat row on the dashboard.
struct QuotaMeterView: View {
    var limit: LimitView?
    /// Mirrors the enclosing SectionCard's header icon (see call sites in
    /// DashboardView) so the oversized background glyph below reads as "this
    /// card, blown up" rather than a random decoration.
    var icon: String = "gauge"
    @Environment(\.appLanguage) private var lang

    private var remaining: Int? {
        guard let used = limit?.usedPercent else { return nil }
        return max(0, Int((100 - used).rounded()))
    }

    /// Same urgency logic as the subscription badge elsewhere: plenty left
    /// reads in the accent color, a shrinking cushion earns amber, and a
    /// near-empty window turns red — the ring's color carries that signal
    /// at a glance, before anyone reads the number.
    private var ringColor: Color {
        guard let remaining else { return Color.notchMutedInk }
        if remaining <= 10 { return Color(red: 1.000, green: 0.380, blue: 0.420) }
        if remaining <= 30 { return Color(red: 1.000, green: 0.720, blue: 0.220) }
        return Color.notchAccent
    }

    private static let ringSize: CGFloat = 60
    private static let ringWidth: CGFloat = 6

    var body: some View {
        ZStack(alignment: .trailing) {
            // The ring + numeral naturally hug the leading edge, leaving the
            // card's trailing half empty — rather than fight that with more
            // Spacers, a ghost of the card's own icon sits back there instead,
            // turning leftover space into a deliberate background motif. Sized
            // and centered to stay fully inside this view's own bounds (no
            // offset past the edge) since SectionCard doesn't clip its content
            // to the card's rounded corners — anything that overflowed here
            // would bleed straight into the neighboring card.
            Image(systemName: icon)
                .font(.system(size: 46, weight: .black))
                .foregroundStyle(ringColor.opacity(0.10))
                .rotationEffect(.degrees(-8))
                .allowsHitTesting(false)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(ringColor.opacity(0.16))
                        .blur(radius: 10)
                        .opacity(remaining == nil ? 0 : 0.6)
                    Circle()
                        .stroke(Color.notchTrack, lineWidth: Self.ringWidth)
                    // A literal water level behind the arc — the arc alone
                    // already encodes the percentage as a sweep angle, but a
                    // rising fill reads at a glance the way a real gauge does,
                    // and doubles down on "this is a dial", not a stat row.
                    if let remaining {
                        RingWaterFill(percent: remaining, color: ringColor)
                            .frame(width: Self.ringSize - Self.ringWidth * 2.6, height: Self.ringSize - Self.ringWidth * 2.6)
                            .clipShape(Circle())
                    }
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining ?? 0) / 100)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.5), value: remaining)
                    // Left empty when there's data — the big numeral beside the
                    // ring is the number to read; duplicating it in miniature
                    // inside the ring too would just compete with it.
                    if remaining == nil {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.notchMutedInk)
                    }
                }
                .frame(width: Self.ringSize, height: Self.ringSize)

                VStack(alignment: .leading, spacing: 4) {
                    if let remaining {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(remaining)")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(ringColor)
                            Text("%")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(ringColor.opacity(0.75))
                            Text(L.remainingWord(lang))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.notchMutedInk)
                        }
                    } else {
                        Text(L.noData(lang))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.notchMutedInk)
                    }
                    // Re-renders every 20s purely from the already-known
                    // `resetsAt` deadline, so the countdown visibly counts
                    // down between data refreshes instead of only updating
                    // once every 30s alongside the rest of the payload.
                    TimelineView(.periodic(from: .now, by: 20)) { _ in
                        Text(Formatting.resetLabel(limit?.resetsAt, lang: lang))
                            .font(.system(size: 10)).foregroundStyle(Color.notchMutedInk)
                    }
                    if let count = limit?.resetCount, count > 0 {
                        Text(L.resetCount(lang, count))
                            .font(.system(size: 9)).foregroundStyle(Color.notchMutedInk.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A sine-wave top edge for `RingWaterFill` — no `animatableData` override,
/// deliberately: `RingWaterFill` redraws this every frame via `TimelineView`
/// with a fresh `phase` already computed from elapsed time, so there's
/// nothing for SwiftUI's own interpolation to do. Declaring animatableData
/// here too would make an unrelated `.animation(value:)` up the view tree
/// try to *also* interpolate between phases, fighting the continuous motion
/// and turning a smooth ripple into a stutter.
private struct WaterWaveShape: Shape {
    var level: CGFloat // 0...1, fraction filled from the bottom
    var phase: CGFloat // radians
    var amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        let baseY = rect.height * (1 - level)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: baseY))
        var x: CGFloat = 0
        while x <= rect.width {
            let y = baseY + amplitude * sin((x / rect.width) * 4 * .pi + phase)
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// The rising fill inside `QuotaMeterView`'s ring — a genuine ripple, not a
/// flat block: two wave layers at slightly different phase/amplitude drift
/// continuously via `TimelineView(.animation)`, which is what keeps the
/// motion going without a repeating `withAnimation` fighting the level
/// changing underneath it every refresh.
private struct RingWaterFill: View {
    var percent: Int
    var color: Color
    /// Driven by `withAnimation` on `percent` changes only — kept separate
    /// from `phase`, which `TimelineView` already updates every frame on its
    /// own, so a quota refresh eases the water level without touching (or
    /// being fought by) the continuous ripple.
    @State private var animatedLevel: CGFloat = 0

    private var targetLevel: CGFloat { CGFloat(max(0, min(100, percent))) / 100 }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                WaterWaveShape(level: animatedLevel, phase: CGFloat(t * 1.3), amplitude: 2.2)
                    .fill(color.opacity(0.22))
                WaterWaveShape(level: animatedLevel, phase: CGFloat(t * 1.7) + .pi / 2, amplitude: 1.4)
                    .fill(
                        LinearGradient(colors: [color.opacity(0.55), color.opacity(0.26)], startPoint: .top, endPoint: .bottom)
                    )
            }
        }
        .onAppear { animatedLevel = targetLevel }
        .onChange(of: percent) { _ in
            withAnimation(.easeOut(duration: 0.6)) { animatedLevel = targetLevel }
        }
    }
}
