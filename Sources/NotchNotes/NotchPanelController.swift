import AppKit
import SwiftUI

@MainActor
final class NotchPanel: NSPanel {
    var onMouseEvent: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }

        if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
            onMouseEvent?(event)
        }

        super.sendEvent(event)
    }
}

@MainActor
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class TransparentHitHostingView<Content: View>: FirstMouseHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        // SwiftUI may return nil when every rendered pixel is transparent.
        // Keep the panel's full compact frame interactive without drawing a background.
        return super.hitTest(point) ?? self
    }
}

@MainActor
final class NotchPanelController: NSObject {
    private let store = NoteStore()
    private let settingsStore = AppSettingsStore()
    private let imageStore = LocalImageStore()
    private let fileShelfStore = FileShelfStore()
    private let workspaceState = NotebookWorkspaceState()
    private let drawerState = DrawerState()
    private let editorInteractionState = EditorInteractionState()
    private let hotPanel: NotchPanel
    private let drawerPanel: NotchPanel
    private var hostingView: NSHostingView<NotebookView>?
    private var hotHostingView: NSHostingView<CompactNotchView>?
    private var mousePollingTimer: Timer?
    private var globalMouseDownMonitor: Any?
    private var globalMouseDragMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var isExpanded = false
    private var activeMenuTrackingCount = 0
    private var collapseTask: DispatchWorkItem?

    override init() {
        hotPanel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        drawerPanel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()
        configurePanel(hotPanel)
        configurePanel(drawerPanel)
        rebuildContent()
        startMousePolling()
        observeScreenChanges()
        observePanelMouseEvents()
        observeGlobalMouseEvents()
        observeMenuTracking()
    }

    func showDocked() {
        let layout = currentLayout()
        rebuildContent(layout: layout)
        isExpanded = false
        drawerState.isExpanded = false
        drawerState.revealProgress = 0
        hotPanel.setFrame(hotFrame(for: layout), display: true)
        hotPanel.orderFrontRegardless()
        drawerPanel.setFrame(drawerFrame(for: layout), display: true)
        drawerPanel.orderOut(nil)
    }

    func expand(animated: Bool, activate: Bool = true) {
        if isExpanded {
            if activate {
                activateEditor()
            }
            return
        }
        let layout = currentLayout()
        cancelCollapse()
        isExpanded = true
        rebuildContent(layout: layout)
        drawerPanel.setFrame(drawerFrame(for: layout), display: true)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            drawerPanel.makeKeyAndOrderFront(nil)
        } else {
            drawerPanel.orderFrontRegardless()
        }
        hotPanel.orderOut(nil)
        setDrawerExpanded(true, animated: animated)
        guard activate else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self else { return }
            guard self.isExpanded else { return }
            self.activateEditor()
        }
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        if let range = editorInteractionState.currentSelectionRange() {
            store.updateSelection(for: store.activeTabID, range: range)
        }
        store.flush(waitForDisk: false)
        isExpanded = false
        setDrawerExpanded(false, animated: animated)
        let delay: TimeInterval = animated ? 0.18 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard !self.isExpanded else { return }
            let layout = self.currentLayout()
            self.drawerPanel.orderOut(nil)
            self.hotPanel.setFrame(self.hotFrame(for: layout), display: true)
            self.hotPanel.orderFrontRegardless()
        }
    }

    func createNote() {
        if let range = editorInteractionState.currentSelectionRange() {
            store.updateSelection(for: store.activeTabID, range: range)
        }
        store.addTab()
        expand(animated: true, activate: true)
    }

    private func configurePanel(_ panel: NotchPanel) {
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
    }

    private func rebuildContent(layout: NotchLayout? = nil) {
        let layout = layout ?? currentLayout()
        let hotView = CompactNotchView(
            layout: layout,
            onFileDragTargeted: { [weak self] isTargeted in
                self?.handleFileDragTargeted(isTargeted)
            },
            onFilesDropped: { [weak self] urls, transferOperation in
                self?.receiveDroppedFiles(
                    urls,
                    transferOperation: transferOperation
                ) ?? false
            }
        )
        let view = NotebookView(
            store: store,
            settingsStore: settingsStore,
            imageStore: imageStore,
            fileShelfStore: fileShelfStore,
            workspaceState: workspaceState,
            drawerState: drawerState,
            editorInteractionState: editorInteractionState,
            layout: layout
        )

        if let hotHostingView {
            hotHostingView.rootView = hotView
        } else {
            let host = TransparentHitHostingView(rootView: hotView)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            hotPanel.contentView = host
            hotHostingView = host
        }

        if let hostingView {
            hostingView.rootView = view
            return
        }

        let host = FirstMouseHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        drawerPanel.contentView = host
        hostingView = host
    }

    private func setDrawerExpanded(_ expanded: Bool, animated: Bool) {
        guard animated else {
            drawerState.isExpanded = expanded
            drawerState.revealProgress = expanded ? 1 : 0
            return
        }

        let animation: Animation = expanded
            ? .spring(response: 0.28, dampingFraction: 0.86)
            : .easeOut(duration: 0.16)

        withAnimation(animation) {
            drawerState.isExpanded = expanded
            drawerState.revealProgress = expanded ? 1 : 0
        }
    }

    private func startMousePolling() {
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(mousePollingTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        mousePollingTimer = timer
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func observePanelMouseEvents() {
        hotPanel.onMouseEvent = { [weak self] event in
            guard let self else { return }
            guard event.type == .leftMouseDown else { return }
            self.expand(animated: true, activate: true)
        }

        drawerPanel.onMouseEvent = { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                NSApp.activate(ignoringOtherApps: true)
                self.drawerPanel.makeKeyAndOrderFront(nil)
            } else if event.type == .leftMouseUp {
                self.workspaceState.isDraggingShelfItem = false
            }
            self.editorInteractionState.handleMouseEvent(event, searchingIn: self.hostingView)
        }

        hotPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
        drawerPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
    }

    private func observeGlobalMouseEvents() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      !self.isExpanded,
                      self.settingsStore.triggerMode == .click,
                      self.activationFrame().contains(NSEvent.mouseLocation) else {
                    return
                }
                self.expand(animated: true, activate: true)
            }
        }

        globalMouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                self?.editorInteractionState.noteGlobalMouseDragged()
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.editorInteractionState.noteGlobalMouseUp()
                self.workspaceState.isDraggingShelfItem = false
                let location = NSEvent.mouseLocation
                if self.isExpanded, !self.isPointInExpandedStayRegion(location) {
                    self.collapse(animated: true)
                } else {
                    self.handleMouseLocation(location)
                }
            }
        }
    }

    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        let layout = currentLayout()
        cancelCollapse()
        rebuildContent(layout: layout)
        hotPanel.setFrame(hotFrame(for: layout), display: true)
        drawerPanel.setFrame(drawerFrame(for: layout), display: true)
    }

    @objc private func mousePollingTick(_ timer: Timer) {
        handleMouseLocation(NSEvent.mouseLocation)
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        activeMenuTrackingCount += 1
        cancelCollapse()
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        activeMenuTrackingCount = max(0, activeMenuTrackingCount - 1)
        guard activeMenuTrackingCount == 0, isExpanded else { return }
        handleMouseLocation(NSEvent.mouseLocation)
    }

    private func handleMouseLocation(_ point: NSPoint) {
        if workspaceState.isShelfDropTargeted {
            workspaceState.shelfDropOperation = NSEvent.modifierFlags.contains(.command)
                ? .cut
                : .copy
        }

        if isExpanded {
            if activeMenuTrackingCount > 0 {
                cancelCollapse()
                return
            }

            if editorInteractionState.isDraggingSelection {
                cancelCollapse()
                return
            }

            if workspaceState.isDraggingShelfItem {
                cancelCollapse()
                return
            }

            if settingsStore.triggerMode == .click || editorInteractionState.hasKeyboardFocus() {
                cancelCollapse()
                return
            }

            if isPointInExpandedStayRegion(point) {
                cancelCollapse()
            } else {
                scheduleCollapse()
            }
            return
        }

        if settingsStore.triggerMode == .hover, activationFrame().contains(point) {
            expand(animated: true, activate: false)
        }
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        guard activeMenuTrackingCount == 0 else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseTask = nil
            guard self.activeMenuTrackingCount == 0 else { return }
            guard !self.editorInteractionState.isDraggingSelection else { return }
            guard !self.workspaceState.isDraggingShelfItem else { return }
            guard !self.isPointInExpandedStayRegion(NSEvent.mouseLocation) else { return }
            self.collapse(animated: true)
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: task)
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func activationFrame() -> NSRect {
        let layout = currentLayout()
        let frame = hotPanel.frame
        guard frame.width > 0, frame.height > 0 else {
            return hotFrame(for: layout)
        }

        return frame
    }

    private func isPointInExpandedStayRegion(_ point: NSPoint) -> Bool {
        let margin: CGFloat = 10
        return drawerPanel.frame.insetBy(dx: -margin, dy: -margin).contains(point)
            || activationFrame().contains(point)
    }

    private func receiveDroppedFiles(
        _ urls: [URL],
        transferOperation: FileShelfTransferOperation
    ) -> Bool {
        let addedCount = fileShelfStore.add(
            urls,
            transferOperation: transferOperation
        )
        workspaceState.isShelfDropTargeted = false
        workspaceState.shelfDropOperation = .copy
        guard addedCount > 0 else { return false }
        expand(animated: true, activate: false)
        return true
    }

    private func handleFileDragTargeted(_ isTargeted: Bool) {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            workspaceState.isShelfDropTargeted = isTargeted
            workspaceState.shelfDropOperation = isTargeted && NSEvent.modifierFlags.contains(.command)
                ? .cut
                : .copy
        }
        if isTargeted {
            expand(animated: true, activate: false)
        }
    }

    func flush() {
        settingsStore.stopKeepingAwake()
        store.flush(waitForDisk: true)
    }

    private func activateEditor() {
        NSApp.activate(ignoringOtherApps: true)
        drawerPanel.makeKeyAndOrderFront(nil)
        editorInteractionState.restoreSelection(
            store.selectionRange(for: store.activeTabID),
            searchingIn: hostingView
        )
        editorInteractionState.requestLayoutRefresh(searchingIn: hostingView)
        editorInteractionState.requestFocus(searchingIn: hostingView)
    }

    private func currentLayout() -> NotchLayout {
        NotchGeometry.layout(for: targetScreen())
    }

    private func targetScreen() -> NSScreen? {
        NotchGeometry.targetScreen()
    }

    private func hotFrame(for layout: NotchLayout) -> NSRect {
        let screen = targetScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return frame(for: layout.compactSize, topY: screenFrame.maxY + layout.compactTopOffset, in: screenFrame)
    }

    private func drawerFrame(for layout: NotchLayout) -> NSRect {
        let screen = targetScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topY = screenFrame.maxY + layout.expandedTopOffset
        return frame(for: layout.expandedSize, topY: topY, in: screenFrame)
    }

    private func frame(for size: NSSize, topY: CGFloat, in screenFrame: NSRect) -> NSRect {
        let x = screenFrame.midX - size.width / 2
        let y = topY - size.height

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
