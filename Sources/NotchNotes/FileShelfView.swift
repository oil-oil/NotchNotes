import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileShelfView: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    let size: CGSize
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var selectionRect: CGRect?
    @State private var selectionAtDragStart: Set<UUID> = []
    @FocusState private var isSelectionFocused: Bool

    private let selectionCoordinateSpace = "file-shelf-selection"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !store.items.isEmpty {
                shelfItems
                    .padding(.horizontal, 6)
                    .opacity(workspaceState.isShelfDropTargeted ? 0.10 : 1)
                    .scaleEffect(workspaceState.isShelfDropTargeted ? 0.985 : 1)
            }

            marqueeEdgeZones
                .allowsHitTesting(!workspaceState.isShelfDropTargeted)

            if workspaceState.isShelfDropTargeted {
                dropPrompt
                    .padding(.top, 10)
                    .padding(.leading, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let selectionRect,
               selectionRect.width >= 3,
               selectionRect.height >= 3 {
                Rectangle()
                    .fill(Color.white.opacity(0.055))
                    .overlay {
                        Rectangle()
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    }
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .offset(x: selectionRect.minX, y: selectionRect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: selectionCoordinateSpace)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(workspaceState.isShelfDropTargeted ? 0.055 : 0.025))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    .white.opacity(workspaceState.isShelfDropTargeted ? 0.16 : 0),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(workspaceState.isShelfDropTargeted ? 0.24 : 0),
            radius: 18,
            y: 8
        )
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: workspaceState.isShelfDropTargeted)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.items)
        .focusable()
        .focused($isSelectionFocused)
        .focusEffectDisabled()
        .onDeleteCommand(perform: removeSelectedItems)
        .onPreferenceChange(FileShelfItemFramePreferenceKey.self) { frames in
            itemFrames = frames
        }
        .onChange(of: store.items.map(\.id)) { _, itemIDs in
            selectedItemIDs.formIntersection(Set(itemIDs))
        }
        .onChange(of: workspaceState.isDraggingShelfItem) { _, isDragging in
            if isDragging {
                cancelMarqueeSelection()
            }
        }
        .onChange(of: workspaceState.isShelfDropTargeted) { _, isTargeted in
            if isTargeted {
                cancelMarqueeSelection()
            }
        }
        .onDisappear(perform: cancelMarqueeSelection)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    store.removeAll()
                }
            } label: {
                Label("Remove All Shelf Items", systemImage: "xmark.circle")
            }
            .disabled(store.items.isEmpty)
        }
    }

    private var dropPrompt: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 9, weight: .semibold))

            Text("Release to add")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.white.opacity(0.58))
    }

    private var shelfItems: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        marqueeGap
                    }

                    FileShelfChip(
                        item: item,
                        store: store,
                        workspaceState: workspaceState,
                        isSelected: selectedItemIDs.contains(item.id),
                        onSelect: { modifiers in
                            select(item.id, modifiers: modifiers)
                        },
                        onDeleteSelected: removeSelectedItems
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: FileShelfItemFramePreferenceKey.self,
                                value: [
                                    item.id: proxy.frame(
                                        in: .named(selectionCoordinateSpace)
                                    )
                                ]
                            )
                        }
                    }
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92))
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var marqueeGap: some View {
        Color.clear
            .frame(width: 5)
            .contentShape(Rectangle())
            .gesture(selectionGesture)
    }

    private var marqueeEdgeZones: some View {
        ZStack {
            VStack(spacing: 0) {
                marqueeStartSurface.frame(height: 6)
                Spacer(minLength: 0)
                marqueeStartSurface.frame(height: 6)
            }

            HStack(spacing: 0) {
                marqueeStartSurface.frame(width: 6)
                Spacer(minLength: 0)
                marqueeStartSurface.frame(width: 6)
            }
        }
    }

    private var marqueeStartSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(selectionGesture)
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(selectionCoordinateSpace))
            .onChanged { value in
                guard !workspaceState.isShelfDropTargeted else { return }

                if selectionRect == nil {
                    selectionAtDragStart = selectedItemIDs
                }

                let rect = CGRect(
                    x: value.startLocation.x,
                    y: value.startLocation.y,
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                ).standardized
                let enclosedIDs = Set(
                    itemFrames.compactMap { id, frame in
                        frame.intersects(rect) ? id : nil
                    }
                )
                let keepsExistingSelection = !NSEvent.modifierFlags
                    .intersection([.command, .shift])
                    .isEmpty

                selectedItemIDs = keepsExistingSelection
                    ? selectionAtDragStart.union(enclosedIDs)
                    : enclosedIDs
                selectionRect = rect
                isSelectionFocused = true
            }
            .onEnded { _ in
                selectionRect = nil
                selectionAtDragStart = []
            }
    }

    private func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        cancelMarqueeSelection()
        isSelectionFocused = true

        if modifiers.contains(.command) {
            if selectedItemIDs.contains(id) {
                selectedItemIDs.remove(id)
            } else {
                selectedItemIDs.insert(id)
            }
        } else if modifiers.contains(.shift) {
            selectedItemIDs.insert(id)
        } else {
            selectedItemIDs = [id]
        }
    }

    private func removeSelectedItems() {
        guard !selectedItemIDs.isEmpty else { return }
        store.remove(ids: selectedItemIDs)
        selectedItemIDs = []
    }

    private func cancelMarqueeSelection() {
        selectionRect = nil
        selectionAtDragStart = []
    }
}

private struct FileShelfItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct FileShelfChip: View {
    let item: FileShelfItem
    @ObservedObject var store: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    let isSelected: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onDeleteSelected: () -> Void
    @State private var isHovering = false

    var body: some View {
        draggableChip
            .task(id: item.fallbackPath) {
                await store.refreshAvailability(item)
            }
    }

    @ViewBuilder
    private var draggableChip: some View {
        if let url, isAvailable {
            chip
                .overlay {
                    FileDragSourceView(
                        url: url,
                        displayName: displayName,
                        onDragBegan: {
                            workspaceState.isDraggingShelfItem = true
                            workspaceState.isShelfDropTargeted = false
                        },
                        onDragEnded: {
                            workspaceState.isDraggingShelfItem = false
                            workspaceState.isShelfDropTargeted = false
                        },
                        onHoverChange: { isHovering = $0 },
                        onSelect: onSelect,
                        onDeleteSelected: onDeleteSelected,
                        onOpen: open,
                        onReveal: revealInFinder,
                        onRemove: removeFromShelf
                    )
                }
        } else {
            chip.onHover { isHovering = $0 }
        }
    }

    private var chip: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: fileIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .opacity(isAvailable ? 1 : 0.34)

                    if !isAvailable {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.72))
                            .background(Circle().fill(Color.black))
                    }
                }

                Text(displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(
                        .white.opacity(
                            isAvailable ? (isSelected ? 0.92 : 0.66) : 0.34
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 52)
            }
            .frame(width: 60, height: 54)

            Button {
                removeFromShelf()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(ShelfRemoveButtonStyle())
            .help("Remove from shelf (file stays on disk)")
            .offset(x: 1, y: -1)
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(isHovering ? 1 : 0.86)
            .allowsHitTesting(isHovering)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    .white.opacity(
                        isSelected ? 0.12 : (isHovering ? 0.065 : 0)
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(isSelected ? 0.20 : 0), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(
            isAvailable
                ? "\(displayName) · \(fileKind)"
                : "\(displayName) is unavailable"
        )
        .accessibilityLabel(displayName)
    }

    private var url: URL? {
        store.resolvedURL(for: item)
    }

    private var isAvailable: Bool {
        store.isAvailable(item)
    }

    private var displayName: String {
        guard let url, isAvailable else { return item.originalName }
        return url.lastPathComponent
    }

    private var fileKind: String {
        if item.isDirectory == true {
            return "Folder"
        }
        return item.fileExtension?.uppercased() ?? "File"
    }

    private var fileIcon: NSImage {
        let contentType: UTType
        if item.isDirectory == true {
            contentType = .folder
        } else if let fileExtension = item.fileExtension,
                  let resolvedType = UTType(filenameExtension: fileExtension) {
            contentType = resolvedType
        } else {
            contentType = .data
        }

        let icon = NSWorkspace.shared.icon(for: contentType)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }

    private func open() {
        guard let url, isAvailable else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url, isAvailable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func removeFromShelf() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            store.remove(item)
        }
    }
}

private struct FileDragSourceView: NSViewRepresentable {
    let url: URL
    let displayName: String
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let onHoverChange: (Bool) -> Void
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onDeleteSelected: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    func makeNSView(context: Context) -> FileDragSourceNSView {
        FileDragSourceNSView()
    }

    func updateNSView(_ nsView: FileDragSourceNSView, context: Context) {
        nsView.url = url
        nsView.displayName = displayName
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.onHoverChange = onHoverChange
        nsView.onSelect = onSelect
        nsView.onDeleteSelected = onDeleteSelected
        nsView.onOpen = onOpen
        nsView.onReveal = onReveal
        nsView.onRemove = onRemove
    }
}

@MainActor
private final class FileDragSourceNSView: NSView, NSDraggingSource {
    var url: URL?
    var displayName = ""
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onDeleteSelected: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?

    private var didStartDrag = false
    private var mouseDownLocation: NSPoint?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let removeButtonArea = NSRect(
            x: bounds.maxX - 20,
            y: bounds.maxY - 20,
            width: 20,
            height: 20
        )
        return removeButtonArea.contains(point) ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        onSelect?(event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelected?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !didStartDrag,
              let mouseDownLocation,
              FileDragGesturePolicy.shouldBegin(from: mouseDownLocation, to: location),
              let url else {
            return
        }
        didStartDrag = true
        onHoverChange?(false)
        onDragBegan?()

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 44, height: 44)

        let draggingItem = NSDraggingItem(
            pasteboardWriter: FileDragPasteboard.writer(for: url)
        )
        draggingItem.setDraggingFrame(
            NSRect(
                x: location.x - 22,
                y: location.y - 22,
                width: 44,
                height: 44
            ),
            contents: icon
        )

        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !didStartDrag, event.clickCount == 2 else { return }
        onOpen?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        menu.addItem(menuItem(title: "Open", action: #selector(openItem)))
        menu.addItem(menuItem(title: "Show in Finder", action: #selector(revealItem)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Remove from Shelf", action: #selector(removeItem)))
        return menu
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        FileDragOperationPolicy.allowedOperations
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?()
        onHoverChange?(false)
        didStartDrag = false
        mouseDownLocation = nil
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openItem() {
        onOpen?()
    }

    @objc private func revealItem() {
        onReveal?()
    }

    @objc private func removeItem() {
        onRemove?()
    }
}

private struct ShelfRemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.58 : 0.82))
            .background(
                Circle()
                    .fill(.black.opacity(configuration.isPressed ? 0.72 : 0.58))
            )
            .contentShape(Circle())
    }
}
