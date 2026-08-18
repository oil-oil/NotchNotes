import AppKit
import XCTest
@testable import NotchNotes

@MainActor
final class NotchGeometryTests: XCTestCase {
    func testActivationFrameMatchesNotchInsteadOfExtendedDropTarget() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = NotchLayout(
            notchSize: NSSize(width: 210, height: 32),
            compactSize: NSSize(width: 204, height: 34),
            expandedSize: NSSize(width: 480, height: 408),
            compactTopOffset: 0,
            expandedTopOffset: 0
        )

        let activationFrame = NotchGeometry.activationFrame(for: layout, in: screenFrame)
        let dropFrame = NotchGeometry.fileDropFrame(for: layout, in: screenFrame)

        XCTAssertEqual(activationFrame.width, 210)
        XCTAssertEqual(activationFrame.height, 34)
        XCTAssertEqual(activationFrame.midX, screenFrame.midX)
        XCTAssertEqual(activationFrame.maxY, screenFrame.maxY)
        XCTAssertEqual(dropFrame.maxY, activationFrame.maxY)
        XCTAssertEqual(
            dropFrame.height - activationFrame.height,
            NotchGeometry.fileDropTargetExtension
        )
    }
}
