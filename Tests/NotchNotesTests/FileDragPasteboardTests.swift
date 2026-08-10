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
}
