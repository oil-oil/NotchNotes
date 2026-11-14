import AppKit
import Foundation
import Testing
@testable import NotchNotes

private final class StubPanelLaunchAtLoginController: LaunchAtLoginControlling {
    var canConfigure = true
    var status: LaunchAtLoginStatus = .notRegistered

    func register() throws {
        status = .enabled
    }

    func unregister() throws {
        status = .notRegistered
    }

    func openApprovalSettings() {}
}

@MainActor
private final class StubPanelSystemSleepGuard: SystemSleepGuardControlling {
    var onUnexpectedStop: (() -> Void)?
    var requiresApproval = false
    var isRunning = false
    private(set) var requestStopCallCount = 0
    private(set) var resetCallCount = 0

    func start() throws {
        isRunning = true
    }

    func waitUntilReady() async throws {}

    func requestStop() {
        requestStopCallCount += 1
        isRunning = false
    }

    func resetSleepIfNeeded(includingLegacyState: Bool) async -> Bool {
        resetCallCount += 1
        isRunning = false
        return true
    }
}

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

    @Test
    func drawerEscapeDismissesSlashMenuBeforeCollapsingDrawer() throws {
        let context = try makeIsolatedController()
        defer { context.cleanup() }

        context.controller.expand(animated: false, activate: false)
        #expect(context.controller.isExpanded)

        context.slashSession.update(
            text: "/h",
            selectedRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )
        #expect(context.slashSession.isPresented)

        context.controller.handleDrawerEscape()
        #expect(!context.slashSession.isPresented)
        #expect(context.controller.isExpanded)

        context.controller.handleDrawerEscape()
        #expect(!context.controller.isExpanded)
    }

    @Test
    func panelCommandsToggleAndCollapseResetsSlashSession() throws {
        let context = try makeIsolatedController()
        defer { context.cleanup() }

        #expect(context.controller.handlePanelCommand(.open))
        #expect(context.controller.isExpanded)

        context.slashSession.update(
            text: "/",
            selectedRange: NSRange(location: 1, length: 0),
            hasMarkedText: false
        )
        #expect(context.slashSession.isPresented)

        #expect(!context.controller.handlePanelCommand(.toggle))
        #expect(!context.controller.isExpanded)
        #expect(!context.slashSession.isPresented)
    }

    @Test
    func statusContextMenuRefreshesLaunchAtLoginState() {
        let suiteName = "NotchNotesTests.StatusMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removeTestSuiteAndPlist(named: suiteName) }

        let launchController = StubPanelLaunchAtLoginController()
        let settingsStore = AppSettingsStore(
            defaults: defaults,
            systemSleepGuard: StubPanelSystemSleepGuard(),
            sleepDisabledState: { false },
            launchAtLoginController: launchController
        )
        let appDelegate = AppDelegate()
        appDelegate.settingsStoreOverrideForTesting = settingsStore

        let menu = appDelegate.makeStatusContextMenu()
        let launchItem = menu.items.first { $0.title == "Launch at Login" }
        #expect(launchItem != nil)
        #expect(launchItem?.state == .off)

        launchController.status = .enabled
        appDelegate.menuNeedsUpdate(menu)
        #expect(launchItem?.state == .on)
        #expect(launchItem?.target as? AppDelegate === appDelegate)
        #expect(launchItem?.action == #selector(AppDelegate.toggleLaunchAtLogin))

        appDelegate.toggleLaunchAtLogin()
        #expect(launchController.status == .notRegistered)
        #expect(launchItem?.state == .off)
    }

    @Test
    func drawerEscapeRespectsMarkedTextAndDismissesFindBarBeforeCollapse() throws {
        let context = try makeIsolatedController()
        defer { context.cleanup() }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.usesFindBar = true
        scrollView.documentView = textView
        context.editorInteractionState.bind(containerView: scrollView, textView: textView)

        context.controller.expand(animated: false, activate: false)
        #expect(context.controller.isExpanded)

        // While IME marked text is active, Esc must pass through to IME instead of dismissing drawer/menus.
        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(textView.hasMarkedText())
        #expect(!context.controller.handleDrawerEscape())
        #expect(context.controller.isExpanded)

        textView.unmarkText()
        #expect(!textView.hasMarkedText())

        // With Find bar visible, first Esc dismisses the Find bar without collapsing the drawer.
        let findBarView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        scrollView.findBarView = findBarView
        scrollView.isFindBarVisible = true
        #expect(scrollView.isFindBarVisible)
        #expect(context.controller.handleDrawerEscape())
        #expect(!scrollView.isFindBarVisible)
        #expect(context.controller.isExpanded)

        // Second Esc collapses the drawer.
        #expect(context.controller.handleDrawerEscape())
        #expect(!context.controller.isExpanded)
    }

    private func makePanel() -> NotchPanel {
        NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func makeIsolatedController() throws -> (
        controller: NotchPanelController,
        slashSession: SlashCommandSession,
        editorInteractionState: EditorInteractionState,
        cleanup: @MainActor () -> Void
    ) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let suiteName = "NotchNotesTests.Panel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = NoteStore(
            defaults: defaults,
            archiveURL: tempDir.appendingPathComponent("notes.json")
        )
        let settingsStore = AppSettingsStore(
            defaults: defaults,
            systemSleepGuard: StubPanelSystemSleepGuard(),
            sleepDisabledState: { false },
            launchAtLoginController: StubPanelLaunchAtLoginController()
        )
        let fileShelfStore = FileShelfStore(defaults: defaults)
        let editorInteractionState = EditorInteractionState()
        let slashSession = SlashCommandSession()
        let controller = NotchPanelController(
            store: store,
            settingsStore: settingsStore,
            fileShelfStore: fileShelfStore,
            editorInteractionState: editorInteractionState,
            slashSession: slashSession,
            startsIPCServer: false,
            startsEventMonitoring: false
        )

        let cleanup: @MainActor () -> Void = {
            controller.flush()
            defaults.removeTestSuiteAndPlist(named: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        return (controller, slashSession, editorInteractionState, cleanup)
    }
}
