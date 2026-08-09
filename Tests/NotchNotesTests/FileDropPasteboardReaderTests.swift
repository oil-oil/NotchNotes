import AppKit
import XCTest
@testable import NotchNotes

@MainActor
final class FileDropPasteboardReaderTests: XCTestCase {
    func testReadsFileURLsInOrderAndRemovesDuplicates() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }

        let firstURL = URL(fileURLWithPath: "/tmp/notch-notes-preview-one.png")
        let secondURL = URL(fileURLWithPath: "/tmp/notch-notes-preview-two.pdf")

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([
                firstURL as NSURL,
                firstURL as NSURL,
                secondURL as NSURL
            ])
        )

        XCTAssertEqual(
            FileDropPasteboardReader.fileURLs(from: pasteboard),
            [firstURL.standardizedFileURL, secondURL.standardizedFileURL]
        )
    }

    func testIgnoresNonFileURLs() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([
                NSURL(string: "https://example.com/image.png")!
            ])
        )

        XCTAssertTrue(FileDropPasteboardReader.fileURLs(from: pasteboard).isEmpty)
    }
}
