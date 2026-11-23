import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEngine
@testable import NotchNotes

@MainActor
final class MarkdownScrollingTests: XCTestCase {
    func testDrawerRoutesWheelToEditor() throws {
        let suite = "ScrollRegression.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NoteStore(defaults: defaults, archiveURL: nil)
        // Mixed-width text and inline code finish wrapping after the initial
        // height calculation; a uniform long list does not reproduce this.
        store.updateText("""
        - [ ]  `ABC-X01` 文文文文文文
        - [x]  文文文文文文、文文文文文
        - [x]  文文文文文文文文文文文文文文文文文文文文文
        - [ ]  `SAMPLE.md` 文文，文文文文文文文 `EXAMPLE`  文文，文文文文，文文文文文文文文 `EXAMPLE` 文文文
        - [ ]  【文文文文】文文文文文文文
        - [ ]   `Other Workflow` 文文(文文文)
        - [x]   文 `Name` 文文文文文文文文文文文 `Other Header` 文文，文文文文文文文文文文文文文文文文文文
        - [x]  文文文文文文 abcde  文文文文
        - [ ]  文文文文文文文文（`other + /example1`）
        - [ ]  文文文文
        """)
        let controller = NotchPanelController(store: store, settingsStore: AppSettingsStore(defaults: defaults), fileShelfStore: FileShelfStore(defaults: defaults), startsIPCServer: false, startsEventMonitoring: false)
        defer { controller.collapse(animated: false); controller.flush() }
        controller.expand(animated: false, activate: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        func find(_ view: NSView) -> NativeTextView? {
            if let text = view as? NativeTextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let panel = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "drawerPanel" }?.value as? NSPanel)
        let editor = try XCTUnwrap(panel.contentView.flatMap(find))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(scroll.verticalScroller?.controlSize, .small)
        let window = try XCTUnwrap(editor.window)
        let root = try XCTUnwrap(window.contentView)
        let point = scroll.convert(NSPoint(x: 100, y: 100), to: root)
        let hit = try XCTUnwrap(root.hitTest(point))
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -150, wheel2: 0, wheel3: 0))
        hit.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let bottom = max(0, editor.measuredBaseContentHeight(minimumHeight: 18) - scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, bottom, accuracy: 1, "The last line must be reachable")
        let firstTab = store.activeTabID
        let shortTab = store.addTab(text: "short", select: false)
        let longTab = store.addTab(text: (1...80).map { "- [ ] Another task \($0)" }.joined(separator: "\n"), select: false)
        for id in [shortTab.id, firstTab, longTab.id, firstTab, shortTab.id, firstTab] {
            store.selectTab(id)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let currentEditor = try XCTUnwrap(panel.contentView.flatMap(find))
            let currentScroll = try XCTUnwrap(currentEditor.enclosingScrollView)
            for step in 0..<20 {
                let down = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0))
                down.setIntegerValueField(.scrollWheelEventScrollPhase, value: step == 0 ? 1 : 2)
                currentEditor.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: down)))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            if id == longTab.id {
                XCTAssertGreaterThan(currentScroll.contentView.bounds.minY, 0, "A longer tab must also scroll")
            } else {
                let expectedBottom = max(0, currentEditor.measuredBaseContentHeight(minimumHeight: 18) - currentScroll.contentView.bounds.height)
                XCTAssertEqual(currentScroll.contentView.bounds.minY, expectedBottom, accuracy: 1, "Must reach the last line after switching tabs")
            }
            let up = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10000, wheel2: 0, wheel3: 0))
            currentEditor.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: up)))
            XCTAssertEqual(currentScroll.contentView.bounds.minY, 0, accuracy: 1, "Scrolling upward must stop at the top")
        }
        withExtendedLifetime(controller) {}
    }

    func testLongChecklistCanScroll() throws {
        let text = (1...60).map { "- [ ] Task \($0) with enough content to fill the editor" }.joined(separator: "\n")
        let host = NSHostingView(rootView: NativeTextViewWrapper(text: .constant(text), configuration: MarkdownEditorConfiguration(overscroll: OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0), scrollers: .vertical, textInsets: TextInsets(horizontal: 12, vertical: 12))))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 280)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        func find(_ view: NSView) -> ClampedScrollView? {
            if let scroll = view as? ClampedScrollView { return scroll }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let scroll = try XCTUnwrap(find(host))
        let editor = try XCTUnwrap(scroll.documentView as? NativeTextView)
        XCTAssertGreaterThan(editor.scrollableContentHeight, scroll.contentView.bounds.height + 100)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -150, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100, "Long document must retain a nonzero scroll offset")
        withExtendedLifetime(window) {}
    }
}
