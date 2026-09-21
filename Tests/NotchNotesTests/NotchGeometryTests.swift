import AppKit
import XCTest
@testable import NotchNotes

@MainActor
final class NotchGeometryTests: XCTestCase {
    func testFallbackActivationHeightDoesNotExtendBelowFallbackNotch() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = NotchGeometry.layout(for: nil)

        let activationFrame = NotchGeometry.activationFrame(for: layout, in: screenFrame)

        XCTAssertEqual(layout.notchSize.height, 32)
        XCTAssertEqual(layout.compactSize.height, 32)
        XCTAssertEqual(activationFrame.height, layout.notchSize.height)
    }

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
        XCTAssertEqual(activationFrame.height, 32)
        XCTAssertEqual(activationFrame.midX, screenFrame.midX)
        XCTAssertEqual(activationFrame.maxY, screenFrame.maxY)
        XCTAssertEqual(dropFrame.maxY, activationFrame.maxY)
        XCTAssertEqual(
            dropFrame.height - activationFrame.height,
            NotchGeometry.fileDropTargetExtension
        )
    }
}
