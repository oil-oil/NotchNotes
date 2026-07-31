import AppKit
import SwiftUI
import XCTest
@testable import NotchNotes

@MainActor
final class TransparentHitHostingViewTests: XCTestCase {
    func testTransparentContentRemainsInteractiveInsideBounds() {
        let hostingView = TransparentHitHostingView(rootView: Color.clear)
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 36)

        XCTAssertNotNil(hostingView.hitTest(NSPoint(x: 100, y: 18)))
        XCTAssertNil(hostingView.hitTest(NSPoint(x: 201, y: 18)))
    }
}
