import AppKit
import MarkdownEngine
import SwiftUI

@MainActor
final class DrawerState: ObservableObject {
    @Published var isExpanded = false
    @Published var revealProgress: CGFloat = 0
}

struct NotebookView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var settingsStore: AppSettingsStore
    let imageStore: LocalImageStore
    @ObservedObject var fileShelfStore: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    @ObservedObject var drawerState: DrawerState
    @ObservedObject var editorInteractionState: EditorInteractionState
    let layout: NotchLayout

    var body: some View {
        ZStack(alignment: .top) {
            drawer
        }
        .frame(width: layout.expandedSize.width, height: layout.expandedSize.height, alignment: .top)
        .dropDestination(for: URL.self) { urls, _ in
            guard !workspaceState.isDraggingShelfItem else {
                workspaceState.isShelfDropTargeted = false
                return false
            }
            return receiveDroppedFiles(urls)
        } isTargeted: { isTargeted in
            withAnimation(shelfAnimation) {
                workspaceState.isShelfDropTargeted = isTargeted
                    && !workspaceState.isDraggingShelfItem
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var drawer: some View {
        ZStack(alignment: .top) {
            expandedContent
                .frame(width: layout.expandedSize.width, height: layout.expandedSize.height)
                .opacity(expandedContentOpacity)
        }
        .frame(width: layout.expandedSize.width, height: layout.expandedSize.height, alignment: .top)
        .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
        .mask(alignment: .top) {
            TopAttachedRoundedShape(radius: cornerRadius)
                .frame(width: revealWidth, height: revealHeight)
        }
        .overlay(alignment: .top) {
            TopAttachedRoundedShape(radius: cornerRadius)
                .stroke(.white.opacity(0.09), lineWidth: 1)
                .frame(width: revealWidth, height: revealHeight)
        }
        .contentShape(Rectangle())
        .allowsHitTesting(drawerState.isExpanded)
    }

    private var expandedContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: editorSpacing) {
                TabPagerControl(
                    store: store,
                    editorInteractionState: editorInteractionState,
                    availableWidth: tabControlWidth
                )
                .frame(
                    width: tabControlWidth,
                    height: tabControlHeight,
                    alignment: .topLeading
                )
                .frame(height: toolbarHeight, alignment: .top)

                VStack(spacing: shelfSpacing) {
                    MarkdownEditorPanel(
                        store: store,
                        settingsStore: settingsStore,
                        imageStore: imageStore,
                        editorInteractionState: editorInteractionState,
                        size: noteEditorSize
                    )
                    .frame(width: noteEditorSize.width, height: noteEditorSize.height)
                    .background(Color(red: 0.06, green: 0.06, blue: 0.07))

                    if isFileShelfVisible {
                        FileShelfView(
                            store: fileShelfStore,
                            workspaceState: workspaceState,
                            size: fileShelfSize
                        )
                        .frame(width: fileShelfSize.width, height: fileShelfSize.height)
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.97, anchor: .bottom))
                        )
                    }
                }
                .animation(shelfAnimation, value: isFileShelfVisible)
            }
        }
        .padding(.top, toolbarTopPadding)
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.bottom, contentBottomPadding)
        .onAppear {
            editorInteractionState.onSelectionChange = { [weak store] range in
                guard let store else { return }
                store.updateSelection(for: store.activeTabID, range: range)
            }
            editorInteractionState.restoreSelection(store.selectionRange(for: store.activeTabID))
        }
        .onChange(of: store.activeTabID) { _, newTabID in
            editorInteractionState.restoreSelection(
                store.selectionRange(for: newTabID),
                reveal: false
            )
        }
        .onDisappear {
            workspaceState.isShelfDropTargeted = false
            workspaceState.isDraggingShelfItem = false
        }
    }

    private var revealWidth: CGFloat {
        interpolate(from: layout.compactSize.width, to: layout.expandedSize.width)
    }

    private var revealHeight: CGFloat {
        interpolate(from: layout.compactSize.height, to: layout.expandedSize.height)
    }

    private var cornerRadius: CGFloat {
        interpolate(from: 12, to: 18)
    }

    private var expandedContentOpacity: CGFloat {
        let progress = drawerState.revealProgress
        return min(max((progress - 0.42) / 0.34, 0), 1)
    }

    private var noteEditorSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            height: max(
                layout.expandedSize.height
                    - toolbarTopPadding
                    - contentBottomPadding
                    - toolbarHeight
                    - editorSpacing
                    - (isFileShelfVisible ? fileShelfHeight + shelfSpacing : 0),
                180
            )
        )
    }

    private var fileShelfSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            height: fileShelfHeight
        )
    }

    private var toolbarTopPadding: CGFloat {
        layout.compactSize.height + 2
    }

    private var contentHorizontalPadding: CGFloat {
        18
    }

    private var contentBottomPadding: CGFloat {
        12
    }

    private var tabControlWidth: CGFloat {
        max(layout.expandedSize.width - contentHorizontalPadding * 2, 220)
    }

    private var tabControlHeight: CGFloat {
        let rowHeight: CGFloat = 24
        let rowSpacing: CGFloat = 4
        let verticalPadding: CGFloat = 4
        return CGFloat(tabRowCount) * rowHeight
            + CGFloat(max(tabRowCount - 1, 0)) * rowSpacing
            + verticalPadding
    }

    private var toolbarHeight: CGFloat {
        max(tabControlHeight, 28)
    }

    private var tabRowCount: Int {
        let availableWidth = max(tabControlWidth - 34, 160)
        var rows = 1
        var currentRowWidth: CGFloat = 0

        for _ in store.tabs {
            let itemWidth: CGFloat = 26

            let proposedWidth = currentRowWidth == 0
                ? itemWidth
                : currentRowWidth + 6 + itemWidth
            if currentRowWidth > 0, proposedWidth > availableWidth {
                rows += 1
                currentRowWidth = itemWidth
            } else {
                currentRowWidth = proposedWidth
            }
        }

        return rows
    }

    private var editorSpacing: CGFloat {
        8
    }

    private var fileShelfHeight: CGFloat {
        72
    }

    private var shelfSpacing: CGFloat {
        8
    }

    private var isFileShelfVisible: Bool {
        workspaceState.isShelfDropTargeted || !fileShelfStore.items.isEmpty
    }

    private var shelfAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.84)
    }

    private func interpolate(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * drawerState.revealProgress
    }

    private func receiveDroppedFiles(_ urls: [URL]) -> Bool {
        let didAcceptDrop = fileShelfStore.acceptDrop(urls)
        workspaceState.isShelfDropTargeted = false
        return didAcceptDrop
    }

}

private struct SettingsMenu: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @State private var isHovering = false

    var body: some View {
        Menu {
            Text("Open NotchNotes · \(settingsStore.triggerMode.title)")

            ForEach(TriggerMode.allCases) { mode in
                Button {
                    settingsStore.triggerMode = mode
                } label: {
                    Label(
                        mode.title,
                        systemImage: settingsStore.triggerMode == mode
                            ? "checkmark"
                            : mode.systemImage
                    )
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 0.88 : 0.76))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(isHovering ? 0.085 : 0.055))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.white.opacity(0.76))
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

private struct KeepAwakeButton: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var steamBurstID = 0

    var body: some View {
        Button {
            settingsStore.toggleKeepAwake()
        } label: {
            ZStack {
                Image(systemName: settingsStore.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")

                if steamBurstID > 0 {
                    CoffeeSteamBurst()
                        .id(steamBurstID)
                        .offset(y: -12)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeepAwakeButtonStyle(isActive: settingsStore.isKeepingAwake))
        .disabled(settingsStore.isChangingKeepAwake)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityValue(settingsStore.isKeepingAwake ? "On" : "Off")
        .onChange(of: settingsStore.isKeepingAwake) { oldValue, newValue in
            if !oldValue, newValue, !reduceMotion {
                steamBurstID += 1
            }
        }
        .alert(
            "Couldn’t Keep Mac Awake",
            isPresented: Binding(
                get: { settingsStore.keepAwakeErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        settingsStore.dismissKeepAwakeError()
                    }
                }
            )
        ) {
            Button("OK") {
                settingsStore.dismissKeepAwakeError()
            }
        } message: {
            Text(settingsStore.keepAwakeErrorMessage ?? "")
        }
    }

    private var helpText: String {
        if settingsStore.isChangingKeepAwake {
            return "Changing keep-awake mode…"
        }
        return settingsStore.isKeepingAwake
            ? "Stop keeping Mac awake"
            : "Keep Mac awake, even with the lid closed"
    }
}

private struct CoffeeSteamBurst: View {
    var body: some View {
        HStack(spacing: 0.5) {
            CoffeeSteamTrail(delay: 0, bend: -1.15, drift: -0.75, height: 10)
            CoffeeSteamTrail(delay: 0.07, bend: 1.05, drift: 0.25, height: 12)
            CoffeeSteamTrail(delay: 0.14, bend: -0.9, drift: 0.75, height: 9)
        }
        .frame(width: 18, height: 14, alignment: .bottom)
    }
}

private struct CoffeeSteamTrail: View {
    let delay: Double
    let bend: CGFloat
    let drift: CGFloat
    let height: CGFloat

    @State private var progress: CGFloat = 0
    @State private var trailOpacity = 0.0

    var body: some View {
        CoffeeSteamCurve(bend: bend)
            .trim(from: max(0, progress - 0.52), to: progress)
            .stroke(
                .white.opacity(0.94),
                style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 4.5, height: height)
            .opacity(trailOpacity)
            .offset(
                x: drift * progress,
                y: 4 - (10 * progress)
            )
            .task {
                do {
                    try await Task.sleep(for: .seconds(delay))

                    withAnimation(.easeOut(duration: 0.16)) {
                        trailOpacity = 0.94
                    }
                    withAnimation(.easeOut(duration: 0.8)) {
                        progress = 1
                    }

                    try await Task.sleep(for: .milliseconds(380))

                    withAnimation(.easeIn(duration: 0.34)) {
                        trailOpacity = 0
                    }
                } catch {
                    trailOpacity = 0
                }
            }
    }
}

private struct CoffeeSteamCurve: Shape {
    let bend: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.midX + bend, y: rect.midY),
            control1: CGPoint(x: rect.midX - bend, y: rect.maxY * 0.82),
            control2: CGPoint(x: rect.midX + (bend * 1.35), y: rect.maxY * 0.64)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.midX + (bend * 0.65), y: rect.maxY * 0.34),
            control2: CGPoint(x: rect.midX - bend, y: rect.maxY * 0.18)
        )
        return path
    }
}

struct MarkdownEditorPanel: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var settingsStore: AppSettingsStore
    let imageStore: LocalImageStore
    let editorInteractionState: EditorInteractionState
    let size: CGSize

    private let toolbarHeight: CGFloat = 38
    private let separatorHeight: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            MarkdownNoteEditor(
                store: store,
                imageStore: imageStore,
                editorInteractionState: editorInteractionState
            )
            .frame(width: size.width, height: editorHeight)

            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(width: size.width, height: separatorHeight)

            MarkdownShortcutToolbar(
                settingsStore: settingsStore,
                editorInteractionState: editorInteractionState
            )
                .frame(width: size.width, height: toolbarHeight)
                .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        }
    }

    private var editorHeight: CGFloat {
        max(size.height - toolbarHeight - separatorHeight, 120)
    }
}

struct MarkdownShortcutToolbar: View {
    @ObservedObject var settingsStore: AppSettingsStore
    let editorInteractionState: EditorInteractionState

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(MarkdownCommand.allCases) { command in
                Button {
                    editorInteractionState.applyMarkdownCommand(command)
                } label: {
                    MarkdownCommandLabel(command: command)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MarkdownToolbarButtonStyle())
                .help(command.help)
            }

            Spacer(minLength: 0)

            KeepAwakeButton(settingsStore: settingsStore)
                .fixedSize()

            SettingsMenu(settingsStore: settingsStore)
                .fixedSize()
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 10)
    }
}

struct MarkdownCommandLabel: View {
    let command: MarkdownCommand

    var body: some View {
        switch command {
        case .bold:
            Image(systemName: "bold")
        case .italic:
            Image(systemName: "italic")
        case .strikethrough:
            Image(systemName: "strikethrough")
        case .inlineCode:
            Text("`")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        case .link:
            Image(systemName: "link")
        case .quote:
            Image(systemName: "quote.opening")
        case .unorderedList:
            Image(systemName: "list.bullet")
        case .orderedList:
            Image(systemName: "list.number")
        case .todoList:
            Image(systemName: "checklist")
        }
    }
}

struct TabPagerControl: View {
    @ObservedObject var store: NoteStore
    let editorInteractionState: EditorInteractionState
    let availableWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            WrappingHStack(
                availableWidth: max(availableWidth - 34, 160),
                horizontalSpacing: 6,
                verticalSpacing: 4
            ) {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == store.activeTabID
                    Button {
                        rememberCurrentSelection()
                        withAnimation(tabSwitchAnimation) {
                            store.selectTab(tab.id)
                        }
                    } label: {
                        ZStack {
                            if isSelected {
                                Circle()
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 14, height: 14)
                            }

                            Circle()
                                .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.34))
                                .frame(width: isSelected ? 7 : 6, height: isSelected ? 7 : 6)
                                .shadow(color: .white.opacity(isSelected ? 0.42 : 0), radius: 3)
                        }
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                        .animation(tabSwitchAnimation, value: isSelected)
                    }
                    .buttonStyle(TabDotButtonStyle(isSelected: isSelected))
                    .help(store.title(for: tab.id))
                    .accessibilityLabel(
                        isSelected
                            ? "Current note: \(store.title(for: tab.id))"
                            : "Open note: \(store.title(for: tab.id))"
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            rememberCurrentSelection()
                            withAnimation(tabSwitchAnimation) {
                                store.removeTab(tab.id)
                            }
                        } label: {
                            Label("Delete This Note", systemImage: "trash")
                        }
                        .disabled(store.tabs.count <= 1)
                    }
                }
            }

            Button {
                rememberCurrentSelection()
                withAnimation(tabSwitchAnimation) {
                    store.addTab()
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabIconButtonStyle())
            .fixedSize()
            .help("New note")
            .accessibilityLabel("New note")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var tabSwitchAnimation: Animation {
        .spring(response: 0.26, dampingFraction: 0.82)
    }

    private func rememberCurrentSelection() {
        guard let range = editorInteractionState.currentSelectionRange() else { return }
        store.updateSelection(for: store.activeTabID, range: range)
    }
}

private struct WrappingHStack: Layout {
    let availableWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = layoutSubviews(in: availableWidth, subviews: subviews)
        return CGSize(width: availableWidth, height: result.size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layoutSubviews(in: min(bounds.width, availableWidth), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func layoutSubviews(
        in availableWidth: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            origins.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }

        return (
            CGSize(width: contentWidth, height: y + rowHeight),
            origins
        )
    }
}

struct CompactNotchView: View {
    let layout: NotchLayout

    var body: some View {
        Color.clear
            .frame(width: layout.compactSize.width, height: layout.compactSize.height + 28)
            .contentShape(Rectangle())
            .pointingHandCursor()
    }
}

struct MarkdownNoteEditor: View {
    @ObservedObject var store: NoteStore
    let imageStore: LocalImageStore
    let editorInteractionState: EditorInteractionState
    @State private var isWikiLinkActive = false
    @State private var pendingInlineReplacement: InlineReplacementRequest?

    var body: some View {
        ZStack(alignment: .topLeading) {
            NativeTextViewWrapper(
                text: Binding(
                    get: { store.text },
                    set: { store.updateText($0) }
                ),
                isWikiLinkActive: $isWikiLinkActive,
                pendingInlineReplacement: $pendingInlineReplacement,
                configuration: configuration,
                fontName: "SF Pro",
                fontSize: 15,
                documentId: store.activeTabID.uuidString,
                isEditable: true,
                onPasteImage: savePastedImage
            )
            .background {
                EditorFocusBinder(state: editorInteractionState)
            }

            if store.text.isEmpty {
                Text("Start typing…")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.24))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private func savePastedImage(_ pasteboard: NSPasteboard) -> String? {
        imageStore.saveImage(from: pasteboard)
    }

    private var configuration: MarkdownEditorConfiguration {
        let theme = MarkdownEditorTheme(
            bodyText: NSColor(white: 0.92, alpha: 1),
            mutedText: NSColor(white: 0.58, alpha: 1),
            disabledText: NSColor(white: 0.38, alpha: 1),
            headingMarker: NSColor(white: 0.44, alpha: 1),
            link: NSColor.systemBlue,
            incompleteLink: NSColor.systemBlue.withAlphaComponent(0.75),
            findMatchHighlight: NSColor.systemYellow.withAlphaComponent(0.55),
            findCurrentMatchHighlight: NSColor.systemYellow,
            latexLightModeText: .white,
            latexDarkModeText: .white,
            strikethroughColor: NSColor(white: 0.62, alpha: 1)
        )

        let services = MarkdownEditorServices(images: imageStore)

        return MarkdownEditorConfiguration(
            theme: theme,
            services: services,
            lists: ListStyle(indentPerLevel: 18, extraLineHeight: 1),
            imageEmbed: ImageEmbedStyle(fallbackMaxWidth: 440, paragraphSpacing: 6, imageGap: 6),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0),
            dragSelection: DragSelectionPolicy(movementThreshold: 8, edgeTriggerDistance: 8, scrollStepPerTick: 4, ticksPerSecond: 30),
            scrollers: .vertical,
            textInsets: TextInsets(horizontal: 12, vertical: 12)
        )
    }
}

struct TopAttachedRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

struct DarkIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 13, weight: .semibold),
            normalOpacity: 0.055,
            hoverOpacity: 0.085,
            pressedOpacity: 0.12,
            strokeOpacity: 0.06,
            foregroundOpacity: 0.76,
            pressedForegroundOpacity: 0.55
        )
    }
}

struct TabIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .bold),
            normalOpacity: 0,
            hoverOpacity: 0.065,
            pressedOpacity: 0.10,
            strokeOpacity: 0,
            foregroundOpacity: 0.72,
            pressedForegroundOpacity: 0.48
        )
    }
}

struct TabDotButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .semibold),
            normalOpacity: 0,
            hoverOpacity: isSelected ? 0.075 : 0.055,
            pressedOpacity: isSelected ? 0.10 : 0.08,
            strokeOpacity: 0,
            foregroundOpacity: 0.72,
            pressedForegroundOpacity: 0.58
        )
    }
}

struct KeepAwakeButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 12, weight: .semibold),
            normalOpacity: isActive ? 0.12 : 0,
            hoverOpacity: isActive ? 0.16 : 0,
            pressedOpacity: isActive ? 0.19 : 0,
            strokeOpacity: isActive ? 0.14 : 0,
            foregroundOpacity: isActive ? 0.94 : 0.76,
            hoverForegroundOpacity: isActive ? 1 : 0.88,
            pressedForegroundOpacity: 0.62
        )
    }
}

struct MarkdownToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .semibold),
            normalOpacity: 0,
            hoverOpacity: 0.065,
            pressedOpacity: 0.10,
            strokeOpacity: 0,
            foregroundOpacity: 0.66,
            hoverForegroundOpacity: 0.84,
            pressedForegroundOpacity: 0.54
        )
    }
}

private struct RoundedHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let font: Font?
    let normalOpacity: CGFloat
    let hoverOpacity: CGFloat
    let pressedOpacity: CGFloat
    let strokeOpacity: CGFloat
    let foregroundOpacity: CGFloat
    let hoverForegroundOpacity: CGFloat
    let pressedForegroundOpacity: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(
        configuration: ButtonStyle.Configuration,
        font: Font?,
        normalOpacity: CGFloat,
        hoverOpacity: CGFloat,
        pressedOpacity: CGFloat,
        strokeOpacity: CGFloat,
        foregroundOpacity: CGFloat,
        hoverForegroundOpacity: CGFloat? = nil,
        pressedForegroundOpacity: CGFloat
    ) {
        self.configuration = configuration
        self.font = font
        self.normalOpacity = normalOpacity
        self.hoverOpacity = hoverOpacity
        self.pressedOpacity = pressedOpacity
        self.strokeOpacity = strokeOpacity
        self.foregroundOpacity = foregroundOpacity
        self.hoverForegroundOpacity = hoverForegroundOpacity ?? foregroundOpacity
        self.pressedForegroundOpacity = pressedForegroundOpacity
    }

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white.opacity(currentForegroundOpacity))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(currentBackgroundOpacity))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(strokeOpacity), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.10), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
            .pointingHandCursor(isEnabled: isEnabled)
    }

    private var currentBackgroundOpacity: CGFloat {
        guard isEnabled else { return 0 }
        if configuration.isPressed {
            return pressedOpacity
        }
        return isHovering ? hoverOpacity : normalOpacity
    }

    private var currentForegroundOpacity: CGFloat {
        guard isEnabled else { return 0.22 }
        if configuration.isPressed {
            return pressedForegroundOpacity
        }
        return isHovering ? hoverForegroundOpacity : foregroundOpacity
    }
}

private extension View {
    func pointingHandCursor(isEnabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isCursorActive = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, isEnabled, !isCursorActive {
                    NSCursor.pointingHand.push()
                    isCursorActive = true
                } else if (!hovering || !isEnabled), isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onDisappear {
                if isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
    }
}
