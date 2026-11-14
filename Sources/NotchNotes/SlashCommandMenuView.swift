import AppKit
import Combine
import SwiftUI

struct SlashCommandMenuView: View {
    private let session: SlashCommandSession
    private let language: AppLanguage
    private let usesSystemWindowShadow: Bool
    private let explicitHeight: CGFloat?
    let onSelect: (SlashCommandItem) -> Void

    init(
        session: SlashCommandSession,
        language: AppLanguage = .english,
        usesSystemWindowShadow: Bool = false,
        explicitHeight: CGFloat? = nil,
        onSelect: @escaping (SlashCommandItem) -> Void
    ) {
        self.session = session
        self.language = language
        self.usesSystemWindowShadow = usesSystemWindowShadow
        self.explicitHeight = explicitHeight
        self.onSelect = onSelect
    }

    var body: some View {
        ObservedSlashCommandMenuContent(
            session: session,
            language: language,
            usesSystemWindowShadow: usesSystemWindowShadow,
            explicitHeight: explicitHeight,
            onSelect: onSelect
        )
    }
}

private struct ObservedSlashCommandMenuContent: View {
    @ObservedObject var session: SlashCommandSession
    let language: AppLanguage
    let usesSystemWindowShadow: Bool
    let explicitHeight: CGFloat?
    let onSelect: (SlashCommandItem) -> Void

    var body: some View {
        if session.isPresented {
            SlashCommandMenuPanel(
                items: session.filteredItems,
                selectedIndex: session.selectedIndex,
                language: language,
                usesSystemWindowShadow: usesSystemWindowShadow,
                explicitHeight: explicitHeight,
                onHoverIndex: { index in
                    if session.filteredItems.indices.contains(index),
                       session.selectedIndex != index {
                        session.selectedIndex = index
                    }
                },
                onSelect: onSelect
            )
        }
    }
}

private struct SlashCommandMenuPanel: View {
    let items: [SlashCommandItem]
    let selectedIndex: Int
    let language: AppLanguage
    let usesSystemWindowShadow: Bool
    let explicitHeight: CGFloat?
    let onHoverIndex: ((Int) -> Void)?
    let onSelect: (SlashCommandItem) -> Void

    @State private var hoveredItemID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SlashCommandRowView(
                            item: item,
                            language: language,
                            isSelected: index == selectedIndex,
                            isHovered: hoveredItemID == item.id,
                            onHoverChange: { hovering in
                                if hovering {
                                    hoveredItemID = item.id
                                    onHoverIndex?(index)
                                } else if hoveredItemID == item.id {
                                    hoveredItemID = nil
                                }
                            },
                            onSelect: {
                                onSelect(item)
                            }
                        )
                        .id(item.id)
                    }
                }
                .padding(SlashCommandEngine.menuPadding)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                scrollToIndex(newIndex, using: proxy, animated: true)
            }
            .onChange(of: items.map(\.id)) { _, _ in
                scrollToIndex(selectedIndex, using: proxy, animated: false)
            }
            .onAppear {
                scrollToIndex(selectedIndex, using: proxy, animated: false)
            }
        }
        .frame(
            width: SlashCommandEngine.menuWidth,
            height: explicitHeight ?? SlashCommandEngine.menuHeight(for: items.count)
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.095, green: 0.098, blue: 0.112).opacity(0.98))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .modifier(SlashMenuShadowModifier(isEnabled: !usesSystemWindowShadow))
        .environment(\.colorScheme, .dark)
    }

    private func scrollToIndex(_ index: Int, using proxy: ScrollViewProxy, animated: Bool) {
        guard items.indices.contains(index) else { return }
        let targetID = items[index].id
        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(targetID, anchor: nil)
            }
        } else {
            proxy.scrollTo(targetID, anchor: nil)
        }
    }
}

private struct SlashCommandRowView: View {
    let item: SlashCommandItem
    let language: AppLanguage
    let isSelected: Bool
    let isHovered: Bool
    let onHoverChange: (Bool) -> Void
    let onSelect: () -> Void

    @State private var isCursorPushed = false

    private var strings: AppStrings {
        AppStrings(language: language)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.white.opacity(iconBackgroundOpacity))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.white.opacity(iconBorderOpacity), lineWidth: 0.5)
                        }

                    Image(systemName: item.iconName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.76))
                }
                .frame(width: 20, height: 20)

                Text(strings.slashItemTitle(item))
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.white.opacity(titleOpacity))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(item.syntaxHint)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(hintOpacity))
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: SlashCommandEngine.rowHeight, maxHeight: SlashCommandEngine.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(rowBackgroundOpacity))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(strings.slashItemHelp(item))
        .accessibilityLabel(strings.slashItemHelp(item))
        .onHover { hovering in
            updateCursor(hovering: hovering)
            onHoverChange(hovering)
        }
        .onDisappear {
            updateCursor(hovering: false)
        }
    }

    private var rowBackgroundOpacity: CGFloat {
        if isSelected {
            return 0.11
        }
        return isHovered ? 0.065 : 0
    }

    private var iconBackgroundOpacity: CGFloat {
        if isSelected {
            return 0.13
        }
        return isHovered ? 0.09 : 0.06
    }

    private var iconBorderOpacity: CGFloat {
        isSelected ? 0.14 : 0.06
    }

    private var titleOpacity: CGFloat {
        if isSelected {
            return 0.96
        }
        return isHovered ? 0.90 : 0.82
    }

    private var hintOpacity: CGFloat {
        if isSelected {
            return 0.56
        }
        return isHovered ? 0.44 : 0.34
    }

    private func updateCursor(hovering: Bool) {
        if hovering, !isCursorPushed {
            NSCursor.pointingHand.push()
            isCursorPushed = true
        } else if !hovering, isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
    }
}

private struct SlashMenuShadowModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .shadow(color: .black.opacity(0.46), radius: 16, x: 0, y: 8)
                .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 1)
        } else {
            content
        }
    }
}

private final class SlashCommandPopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SlashCommandPopupController {
    private weak var parentWindow: NSWindow?
    private let store: NoteStore
    private let settingsStore: AppSettingsStore
    private let editorInteractionState: EditorInteractionState
    private let slashSession: SlashCommandSession
    private let allowsWindowPresentation: Bool
    var isDrawerExpanded: () -> Bool

    private let panel: SlashCommandPopupPanel
    private let hostingView: FirstMouseHostingView<SlashCommandMenuView>
    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
    private var syncToken = 0
    private(set) var lastPlacement: SlashMenuPlacement?

    var isVisible: Bool {
        panel.isVisible
    }

    var visibleFrame: NSRect? {
        panel.isVisible ? panel.frame : nil
    }

    init(
        parentWindow: NSWindow?,
        store: NoteStore,
        settingsStore: AppSettingsStore,
        editorInteractionState: EditorInteractionState,
        slashSession: SlashCommandSession,
        allowsWindowPresentation: Bool,
        isDrawerExpanded: @escaping () -> Bool = { false }
    ) {
        self.parentWindow = parentWindow
        self.store = store
        self.settingsStore = settingsStore
        self.editorInteractionState = editorInteractionState
        self.slashSession = slashSession
        self.allowsWindowPresentation = allowsWindowPresentation
        self.isDrawerExpanded = isDrawerExpanded

        let panel = SlashCommandPopupPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        self.panel = panel

        let rootView = SlashCommandMenuView(
            session: slashSession,
            language: settingsStore.language,
            usesSystemWindowShadow: true
        ) { _ in }
        let host = FirstMouseHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.hostingView = host

        observeChanges()
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver(_:))
    }

    private func observeChanges() {
        slashSession.$activeMatch
            .combineLatest(
                slashSession.$filteredItems,
                slashSession.$isComposingMarkedText,
                settingsStore.$language
            )
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSync()
            }
            .store(in: &cancellables)

        editorInteractionState.onViewportScroll = { [weak self] in
            self?.sync()
        }
        editorInteractionState.onSlashSessionDidUpdate = { [weak self] in
            self?.syncAndVerifyNextTick()
        }
        editorInteractionState.onEditorFocusLost = { [weak self] in
            self?.hide()
        }

        let scheduleHide: @Sendable (Notification) -> Void = { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.hide()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            }
        }

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: nil,
                using: scheduleHide
            )
        )
        if let parentWindow {
            notificationObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: parentWindow,
                    queue: nil,
                    using: scheduleHide
                )
            )
        }
    }

    private func scheduleSync() {
        syncToken += 1
        let expectedToken = syncToken
        DispatchQueue.main.async { [weak self] in
            guard let self, self.syncToken == expectedToken else { return }
            self.sync()
        }
    }

    func syncAndVerifyNextTick() {
        sync()
        scheduleSync()
    }

    func sync() {
        guard isDrawerExpanded(),
              slashSession.isPresented,
              !slashSession.isComposingMarkedText,
              (!allowsWindowPresentation || editorInteractionState.hasKeyboardFocus(requireActiveKeyWindow: true)),
              let match = slashSession.activeMatch,
              let caretScreenRect = editorInteractionState.screenRectForSlashTrigger(match) else {
            hide()
            return
        }

        let anchorPoint = CGPoint(x: caretScreenRect.midX, y: caretScreenRect.midY)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? parentWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenVisibleFrame = targetScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let placement = SlashCommandEngine.screenMenuPlacement(
            caretScreenRect: caretScreenRect,
            screenVisibleFrame: screenVisibleFrame,
            itemCount: slashSession.filteredItems.count
        )
        lastPlacement = placement

        hostingView.rootView = SlashCommandMenuView(
            session: slashSession,
            language: settingsStore.language,
            usesSystemWindowShadow: true,
            explicitHeight: placement.size.height
        ) { [weak self] item in
            guard let self else { return }
            _ = self.editorInteractionState.commitSlashCommand(
                item,
                slashSession: self.slashSession,
                fallbackText: self.store.text
            )
        }

        if panel.frame != placement.frame {
            panel.setFrame(placement.frame, display: allowsWindowPresentation)
        }
        hostingView.frame = NSRect(origin: .zero, size: placement.frame.size)

        guard allowsWindowPresentation else { return }

        if let parentWindow, panel.parent !== parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        lastPlacement = nil
        if let currentParent = panel.parent {
            currentParent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }
}
