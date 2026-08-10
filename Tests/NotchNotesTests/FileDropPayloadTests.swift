import XCTest
@testable import NotchNotes

final class FileDropPayloadTests: XCTestCase {
    func testNormalizesFileURLsInOrderAndRemovesDuplicates() {
        let firstURL = URL(fileURLWithPath: "/tmp/notch-notes-preview-one.png")
        let secondURL = URL(fileURLWithPath: "/tmp/notch-notes-preview-two.pdf")

        XCTAssertEqual(
            FileDropPayload.normalizedFileURLs(
                from: [firstURL, firstURL, secondURL]
            ),
            [firstURL.standardizedFileURL, secondURL.standardizedFileURL]
        )
    }

    func testIgnoresNonFileURLs() {
        let webURL = URL(string: "https://example.com/image.png")!

        XCTAssertTrue(FileDropPayload.normalizedFileURLs(from: [webURL]).isEmpty)
    }
}
