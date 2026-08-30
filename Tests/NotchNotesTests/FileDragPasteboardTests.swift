import AppKit
import XCTest
@testable import NotchNotes

@MainActor
final class FileDragPasteboardTests: XCTestCase {
    func testUsesNativeFileURLWriter() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }

        let url = URL(fileURLWithPath: "/tmp/notch notes upload.pdf")
            .standardizedFileURL
        pasteboard.clearContents()

        XCTAssertTrue(pasteboard.writeObjects([FileDragPasteboard.writer(for: url)]))
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(item.types, [.fileURL])
        XCTAssertEqual(item.string(forType: .fileURL), url.absoluteString)
    }

    func testFileRepresentationCanBeReadByDropTargets() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }

        let url = URL(fileURLWithPath: "/tmp/notch-notes-upload.txt")
            .standardizedFileURL
        pasteboard.clearContents()

        XCTAssertTrue(pasteboard.writeObjects([FileDragPasteboard.writer(for: url)]))

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(objects, [url])
    }

    func testExternalDragSupportsOnlyNonDestructiveOperations() {
        let operations = FileDragOperationPolicy.allowedOperations

        XCTAssertTrue(operations.contains(.copy))
        XCTAssertTrue(operations.contains(.generic))
        XCTAssertFalse(operations.contains(.move))
        XCTAssertFalse(operations.contains(.delete))
    }

    func testFileDragRequiresIntentionalPointerMovement() {
        XCTAssertFalse(
            FileDragGesturePolicy.shouldBegin(
                from: NSPoint(x: 10, y: 10),
                to: NSPoint(x: 15, y: 15)
            )
        )
        XCTAssertTrue(
            FileDragGesturePolicy.shouldBegin(
                from: NSPoint(x: 10, y: 10),
                to: NSPoint(x: 18, y: 10)
            )
        )
    }

    func testStaleFileURLDoesNotTurnAnOrdinaryClickIntoAFileDrag() {
        let pasteboard = makeFilePasteboard()
        defer { pasteboard.clearContents() }

        var state = FileDragTrackingState()
        state.mouseDown(at: NSPoint(x: 10, y: 10), pasteboardChangeCount: pasteboard.changeCount)

        XCTAssertFalse(
            state.shouldTreatAsFileDrag(
                at: NSPoint(x: 50, y: 50),
                isLeftMouseButtonDown: true,
                pasteboard: pasteboard,
                fileDropFrame: NSRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
    }

    func testUpdatedFileURLStillNeedsEightPointMovement() {
        let pasteboard = makeFilePasteboard()
        defer { pasteboard.clearContents() }

        var state = FileDragTrackingState()
        state.mouseDown(at: NSPoint(x: 10, y: 10), pasteboardChangeCount: pasteboard.changeCount)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([FileDragPasteboard.writer(for: URL(fileURLWithPath: "/tmp/new-file.txt"))]))
        state.mouseDragged(to: NSPoint(x: 15, y: 15))

        XCTAssertFalse(
            state.shouldTreatAsFileDrag(
                at: NSPoint(x: 50, y: 50),
                isLeftMouseButtonDown: true,
                pasteboard: pasteboard,
                fileDropFrame: NSRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
    }

    func testUpdatedFileURLAndEightPointMovementBeginFileDrag() {
        let pasteboard = makeFilePasteboard()
        defer { pasteboard.clearContents() }

        var state = FileDragTrackingState()
        state.mouseDown(at: NSPoint(x: 10, y: 10), pasteboardChangeCount: pasteboard.changeCount)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([FileDragPasteboard.writer(for: URL(fileURLWithPath: "/tmp/new-file.txt"))]))
        state.mouseDragged(to: NSPoint(x: 18, y: 10))

        XCTAssertTrue(
            state.shouldTreatAsFileDrag(
                at: NSPoint(x: 50, y: 50),
                isLeftMouseButtonDown: true,
                pasteboard: pasteboard,
                fileDropFrame: NSRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
    }

    func testMouseUpClearsFileDragIntent() {
        let pasteboard = makeFilePasteboard()
        defer { pasteboard.clearContents() }

        var state = FileDragTrackingState()
        state.mouseDown(at: NSPoint(x: 10, y: 10), pasteboardChangeCount: pasteboard.changeCount)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([FileDragPasteboard.writer(for: URL(fileURLWithPath: "/tmp/new-file.txt"))]))
        state.mouseDragged(to: NSPoint(x: 18, y: 10))
        state.mouseUp()

        XCTAssertFalse(
            state.shouldTreatAsFileDrag(
                at: NSPoint(x: 50, y: 50),
                isLeftMouseButtonDown: true,
                pasteboard: pasteboard,
                fileDropFrame: NSRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
    }

    private func makeFilePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([
                FileDragPasteboard.writer(for: URL(fileURLWithPath: "/tmp/stale-file.txt"))
            ])
        )
        return pasteboard
    }
}
