import XCTest
@testable import aibar

final class ScreenshotAnnotationTests: XCTestCase {
    func testAnnotationsReceiveSequentialNumbers() {
        var history = ScreenshotAnnotationHistory()
        history.append(ScreenshotAnnotation(
            number: 99, tool: .rectangle,
            points: [CGPoint(x: 20, y: 10), CGPoint(x: 120, y: 80)]
        ))
        history.append(ScreenshotAnnotation(
            number: 99, tool: .arrow,
            points: [CGPoint(x: 140, y: 90), CGPoint(x: 220, y: 160)]
        ))

        XCTAssertEqual(history.annotations.map(\.number), [1, 2])
        XCTAssertEqual(history.nextNumber, 3)
    }

    func testUndoMakesTheNumberAvailableAgain() {
        var history = ScreenshotAnnotationHistory()
        history.append(ScreenshotAnnotation(
            number: 1, tool: .oval,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)]
        ))
        history.append(ScreenshotAnnotation(
            number: 2, tool: .pen,
            points: [CGPoint(x: 40, y: 40), CGPoint(x: 45, y: 50)]
        ))

        XCTAssertEqual(history.undo()?.number, 2)
        XCTAssertEqual(history.nextNumber, 2)
    }

    func testTinyAccidentalMarksAreDiscarded() {
        var history = ScreenshotAnnotationHistory()
        history.append(ScreenshotAnnotation(
            number: 1, tool: .rectangle,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 11)]
        ))
        XCTAssertTrue(history.annotations.isEmpty)
    }

    func testBoundsUseTopLeftRegardlessOfDragDirection() {
        let annotation = ScreenshotAnnotation(
            number: 1, tool: .rectangle,
            points: [CGPoint(x: 100, y: 80), CGPoint(x: 20, y: 10)]
        )
        XCTAssertEqual(annotation.bounds, CGRect(x: 20, y: 10, width: 80, height: 70))
    }

    func testHistoryPreservesTheColorChosenForEachAnnotation() {
        var history = ScreenshotAnnotationHistory()
        let blue = ScreenshotAnnotationColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        history.append(ScreenshotAnnotation(
            number: 1, tool: .rectangle,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 80)],
            color: blue
        ))

        XCTAssertEqual(history.annotations.first?.color, blue)
    }

    func testArrowTextRequiresTextAndKeepsItAtTheArrowAnnotation() {
        var history = ScreenshotAnnotationHistory()
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 160, y: 100)]
        history.append(ScreenshotAnnotation(number: 1, tool: .arrowText, points: points))
        XCTAssertTrue(history.annotations.isEmpty)

        history.append(ScreenshotAnnotation(
            number: 1, tool: .arrowText, points: points, text: "检查这里"
        ))
        XCTAssertEqual(history.annotations.first?.tool, .arrowText)
        XCTAssertEqual(history.annotations.first?.text, "检查这里")
        XCTAssertEqual(history.annotations.first?.points.first, points.first)
        XCTAssertEqual(history.annotations.count, 1, "箭头和文字应当作为一次组合批注")
        XCTAssertEqual(history.nextNumber, 2, "一次组合批注只能占用一个编号")
    }

    func testDeletingAnAnnotationRenumbersEverythingAfterIt() {
        var history = ScreenshotAnnotationHistory()
        for offset in 0..<3 {
            history.append(ScreenshotAnnotation(
                number: 99,
                tool: .rectangle,
                points: [
                    CGPoint(x: CGFloat(offset * 20), y: 0),
                    CGPoint(x: CGFloat(offset * 20 + 10), y: 10),
                ]
            ))
        }

        let removed = history.remove(at: 1)
        XCTAssertEqual(removed?.number, 2)
        XCTAssertEqual(history.annotations.map(\.number), [1, 2])
        XCTAssertEqual(history.nextNumber, 3)
    }

    func testUndoRestoresADeletedAnnotationAndItsOriginalSequence() {
        var history = ScreenshotAnnotationHistory()
        for offset in 0..<3 {
            history.append(ScreenshotAnnotation(
                number: offset + 1,
                tool: .arrow,
                points: [
                    CGPoint(x: CGFloat(offset * 20), y: 0),
                    CGPoint(x: CGFloat(offset * 20 + 10), y: 10),
                ]
            ))
        }
        _ = history.remove(at: 0)

        _ = history.undo()
        XCTAssertEqual(history.annotations.map(\.number), [1, 2, 3])
        XCTAssertEqual(history.annotations.first?.points.first?.x, 0)
    }

    func testEmptyEditorRequiresASecondCloseWithinTheConfirmationWindow() {
        var guardState = EmptyEditorCloseGuard()
        let firstClick = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(guardState.shouldClose(annotationCount: 0, now: firstClick))
        XCTAssertTrue(guardState.shouldClose(
            annotationCount: 0,
            now: firstClick.addingTimeInterval(1)
        ))
    }

    func testEmptyEditorCloseConfirmationExpiresAndMarkedEditorsCloseDirectly() {
        var guardState = EmptyEditorCloseGuard()
        let firstClick = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(guardState.shouldClose(annotationCount: 0, now: firstClick))
        XCTAssertFalse(guardState.shouldClose(
            annotationCount: 0,
            now: firstClick.addingTimeInterval(3)
        ))
        XCTAssertTrue(guardState.shouldClose(
            annotationCount: 1,
            now: firstClick.addingTimeInterval(3.1)
        ))
    }
}
