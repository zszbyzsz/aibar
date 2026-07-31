import CoreGraphics
import Foundation

enum ScreenshotAnnotationTool: Int, CaseIterable {
    case rectangle
    case arrow
    case oval
    case pen
    case arrowText
}

struct ScreenshotAnnotationColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let red = ScreenshotAnnotationColor(red: 1, green: 0.231, blue: 0.188, alpha: 1)
}

struct ScreenshotAnnotation: Equatable {
    let number: Int
    let tool: ScreenshotAnnotationTool
    var points: [CGPoint]
    var color: ScreenshotAnnotationColor = .red
    var text: String? = nil

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            result.union(CGRect(origin: point, size: .zero))
        }.standardized
    }

    var isMeaningful: Bool {
        switch tool {
        case .pen:
            return points.count > 1 && bounds.width + bounds.height >= 4
        case .rectangle, .arrow, .oval, .arrowText:
            guard let first = points.first, let last = points.last else { return false }
            return hypot(last.x - first.x, last.y - first.y) >= 4
        }
    }
}

struct ScreenshotAnnotationHistory {
    private(set) var annotations: [ScreenshotAnnotation] = []
    private var undoSnapshots: [[ScreenshotAnnotation]] = []

    var nextNumber: Int { annotations.count + 1 }

    mutating func append(_ annotation: ScreenshotAnnotation) {
        guard annotation.isMeaningful else { return }
        if annotation.tool == .arrowText {
            guard let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
        }
        undoSnapshots.append(annotations)
        annotations.append(ScreenshotAnnotation(
            number: nextNumber,
            tool: annotation.tool,
            points: annotation.points,
            color: annotation.color,
            text: annotation.text
        ))
    }

    @discardableResult
    mutating func remove(at index: Int) -> ScreenshotAnnotation? {
        guard annotations.indices.contains(index) else { return nil }
        undoSnapshots.append(annotations)
        let removed = annotations.remove(at: index)
        renumberAnnotations()
        return removed
    }

    @discardableResult
    mutating func undo() -> ScreenshotAnnotation? {
        guard let snapshot = undoSnapshots.popLast() else { return nil }
        let changed = annotations.last
        annotations = snapshot
        return changed
    }

    private mutating func renumberAnnotations() {
        annotations = annotations.enumerated().map { offset, annotation in
            ScreenshotAnnotation(
                number: offset + 1,
                tool: annotation.tool,
                points: annotation.points,
                color: annotation.color,
                text: annotation.text
            )
        }
    }
}

struct EmptyEditorCloseGuard {
    private(set) var armedUntil: Date?

    mutating func shouldClose(
        annotationCount: Int,
        now: Date = Date(),
        confirmationInterval: TimeInterval = 2
    ) -> Bool {
        guard annotationCount == 0 else {
            armedUntil = nil
            return true
        }
        if let armedUntil, now <= armedUntil {
            self.armedUntil = nil
            return true
        }
        armedUntil = now.addingTimeInterval(confirmationInterval)
        return false
    }

    mutating func reset() {
        armedUntil = nil
    }
}
