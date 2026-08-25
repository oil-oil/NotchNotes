import AppKit
import Testing
@testable import NotchNotes

@MainActor
struct NotchPanelActivationTests {
    @Test
    func panelIsPassiveByDefault() {
        let panel = makePanel()

        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test
    func panelBecomesFocusableOnlyAfterExplicitActivation() {
        let panel = makePanel()

        panel.allowsKeyActivation = true
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain)

        panel.allowsKeyActivation = false
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    private func makePanel() -> NotchPanel {
        NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }
}
