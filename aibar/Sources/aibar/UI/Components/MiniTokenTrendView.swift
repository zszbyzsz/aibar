import SwiftUI

/// A compact, data-backed sparkline for dense dashboard rows. It deliberately
/// omits axes and labels at this size; the surrounding row already provides
/// the time window and exact total, while the line makes direction and bursts
/// visible in the otherwise empty space beside the main value.
struct MiniTokenTrendView: View {
    var values: [Int]
    var color: Color
    var height: CGFloat = 30

    @Environment(\.appLanguage) private var lang

    private var hasData: Bool { values.contains { $0 > 0 } }

    private var plottedValues: [Double] {
        let maxPoints = 36
        guard values.count > maxPoints else { return values.map(Double.init) }

        let bucketWidth = Double(values.count) / Double(maxPoints)
        return (0..<maxPoints).map { index in
            let start = min(values.count - 1, Int((Double(index) * bucketWidth).rounded(.down)))
            let end = min(values.count, max(start + 1, Int((Double(index + 1) * bucketWidth).rounded(.up))))
            let bucket = values[start..<end]
            return bucket.reduce(0.0) { $0 + Double($1) } / Double(bucket.count)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let points = normalizedPoints(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.notchTrack.opacity(0.68))

                if hasData, !points.isEmpty {
                    areaPath(points, height: geo.size.height)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.30), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(points)
                        .stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                    if let last = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: 4, height: 4)
                            .position(last)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.notchMutedInk)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.tokenTrendAccessibilityLabel(lang))
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !plottedValues.isEmpty else { return [] }
        guard plottedValues.count > 1 else {
            return [CGPoint(x: size.width / 2, y: size.height / 2)]
        }

        let minValue = plottedValues.min() ?? 0
        let maxValue = plottedValues.max() ?? 0
        let range = maxValue - minValue
        let verticalInset: CGFloat = 4
        let plotHeight = max(size.height - verticalInset * 2, 1)

        return plottedValues.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(plottedValues.count - 1)
            let normalized = range > 0 ? (value - minValue) / range : 0.5
            let y = verticalInset + plotHeight * CGFloat(1 - normalized)
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let midpoint = (start.x + end.x) / 2
            path.addCurve(
                to: end,
                control1: CGPoint(x: midpoint, y: start.y),
                control2: CGPoint(x: midpoint, y: end.y)
            )
        }
        return path
    }

    private func areaPath(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = linePath(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.addLine(to: CGPoint(x: first.x, y: height))
        path.closeSubpath()
        return path
    }
}
