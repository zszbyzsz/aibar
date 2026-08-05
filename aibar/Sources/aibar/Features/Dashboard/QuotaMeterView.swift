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
    var isCompact: Bool = false
    @Environment(\.appLanguage) private var lang
    /// Kept separate from the water level so the ring can always draw from
    /// zero to the current value, including on its first appearance.
    @State private var animatedRingProgress: CGFloat = 0

    private var remaining: Int? {
        guard let used = limit?.usedPercent else { return nil }
        return max(0, Int((100 - used).rounded()))
    }

    /// Five colors turn the remaining quota into a quick visual scale: blue,
    /// green, yellow, orange, then red as the available cushion shrinks.
    private var ringColor: Color {
        QuotaStatusPalette.color(
            remaining: remaining,
            normal: .notchAccent,
            unavailable: .notchMutedInk
        )
    }

    private static let ringSize: CGFloat = 60
    private static let ringWidth: CGFloat = 6

    private var regularMeter: some View {
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
                        .trim(from: 0, to: animatedRingProgress)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
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

    private var compactMeter: some View {
        ZStack {
            Circle()
                .fill(ringColor.opacity(0.16))
                .blur(radius: 8)
                .opacity(remaining == nil ? 0 : 0.58)
            Circle()
                .stroke(Color.notchInk.opacity(0.16), lineWidth: 6)
            if let remaining {
                RingWaterFill(percent: remaining, color: ringColor)
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
            }
            Circle()
                .trim(from: 0, to: animatedRingProgress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let remaining {
                outlinedCompactPercentage(remaining)
            } else {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.notchMutedInk)
            }
        }
        .frame(width: 60, height: 60)
    }

    /// The percentage stays inside the dial, where it belongs semantically,
    /// but gets an explicit dark outline so the animated water fill cannot
    /// visually swallow the number at a glance.
    @ViewBuilder
    private func outlinedCompactPercentage(_ remaining: Int) -> some View {
        let label = Text("\(remaining)%")
            .font(.system(size: 16.5, weight: .heavy, design: .rounded))
            .monospacedDigit()

        ZStack {
            label.foregroundStyle(Color.black.opacity(0.9)).offset(x: -1, y: 0)
            label.foregroundStyle(Color.black.opacity(0.9)).offset(x: 1, y: 0)
            label.foregroundStyle(Color.black.opacity(0.9)).offset(x: 0, y: -1)
            label.foregroundStyle(Color.black.opacity(0.9)).offset(x: 0, y: 1)
            label
                .foregroundStyle(ringColor)
                .shadow(color: Color.white.opacity(0.16), radius: 1)
        }
    }

    var body: some View {
        Group {
            if isCompact {
                compactMeter
            } else {
                regularMeter
            }
        }
        .onAppear {
            // Deferring the state change lets SwiftUI commit the empty ring
            // first, so the visible sweep begins at 0 rather than appearing
            // already filled on the initial render.
            animatedRingProgress = 0
            let targetProgress = CGFloat(remaining ?? 0) / 100
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.6)) {
                    animatedRingProgress = targetProgress
                }
            }
        }
        .onChange(of: remaining) { newRemaining in
            withAnimation(.easeOut(duration: 0.6)) {
                animatedRingProgress = CGFloat(newRemaining ?? 0) / 100
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

/// A narrow moving glint along the waterline. It is intentionally a separate
/// shape from the fill, so the liquid keeps a legible surface even at low
/// opacity and the highlight can drift without affecting the fill level.
private struct WaterWaveLine: Shape {
    var level: CGFloat
    var phase: CGFloat
    var amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        let baseY = rect.height * (1 - level)
        var path = Path()
        var x: CGFloat = 0
        path.move(to: CGPoint(x: x, y: baseY + amplitude * sin(phase)))
        while x <= rect.width {
            let y = baseY + amplitude * sin((x / rect.width) * 4 * .pi + phase)
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
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
    /// Driven by `withAnimation` on appearance and `percent` changes — kept
    /// separate from `phase`, which `TimelineView` already updates every
    /// frame on its own, so a quota refresh eases the water level without
    /// touching (or being fought by) the continuous ripple.
    @State private var animatedLevel: CGFloat = 0

    private var targetLevel: CGFloat { CGFloat(max(0, min(100, percent))) / 100 }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                WaterWaveShape(level: animatedLevel, phase: CGFloat(t * 1.3), amplitude: 2.2)
                    .fill(color.opacity(0.36))
                WaterWaveShape(level: animatedLevel, phase: CGFloat(t * 1.7) + .pi / 2, amplitude: 1.4)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: color.opacity(0.88), location: 0),
                                .init(color: color.opacity(0.56), location: 0.38),
                                .init(color: color.opacity(0.22), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                // A restrained specular line gives the wave a living surface
                // rather than making the whole fill pulse or bounce.
                WaterWaveLine(level: animatedLevel, phase: CGFloat(t * 1.3), amplitude: 1.1)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.62),
                                color.opacity(0.82),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
                    )
            }
        }
        .onAppear {
            // Start at the bottom and defer the target assignment by one run
            // loop so the initial empty-water frame is actually rendered.
            animatedLevel = 0
            let initialLevel = self.targetLevel
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.6)) {
                    animatedLevel = initialLevel
                }
            }
        }
        .onChange(of: percent) { _ in
            withAnimation(.easeOut(duration: 0.6)) { animatedLevel = targetLevel }
        }
    }
}
