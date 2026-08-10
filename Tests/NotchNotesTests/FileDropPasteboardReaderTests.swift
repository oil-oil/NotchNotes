import AppKit
import SwiftUI
import XCTest
@testable import NotchNotes

@MainActor
final class FileDropPasteboardReaderTests: XCTestCase {
    func testReadsNativeFileURLsInOrderAndRemovesDuplicates() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }

        let firstURL = URL(fileURLWithPath: "/tmp/notch-notes-drop-one.png")
        let secondURL = URL(fileURLWithPath: "/tmp/notch-notes-drop-two.pdf")
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([
                firstURL as NSURL,
                firstURL as NSURL,
                secondURL as NSURL
            ])
        )
        XCTAssertTrue(FileDropPasteboardReader.containsFileURLs(pasteboard))

        XCTAssertEqual(
            FileDropPasteboardReader.fileURLs(from: pasteboard),
            [firstURL.standardizedFileURL, secondURL.standardizedFileURL]
        )
    }

    func testCompactTargetRegistersForNativeFileURLs() {
        let targetView = CompactFileDropHostingView(rootView: Color.clear)

        XCTAssertTrue(targetView.registeredDraggedTypes.contains(.fileURL))
    }
}
