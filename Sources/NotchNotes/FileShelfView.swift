import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct FileShelfView: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    let size: CGSize
    @StateObject private var previewController = FileShelfPreviewController()
    @State private var selection = FileShelfSelection()
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var selectionRect: CGRect?
    @State private var selectionAtDragStart: Set<UUID> = []
    @State private var keyboardFocusGeneration = 0

    private let selectionCoordinateSpace = "file-shelf-selection"

    var body: some View {
        ZStack(alignment: .topLeading) {
            FileShelfKeyboardFocusView(
                focusGeneration: keyboardFocusGeneration,
                onSelectAll: selectAllItems,
                onPreview: { previewSelection() },
                onDelete: removeSelectedItems
            )
            .allowsHitTesting(false)

            if !store.items.isEmpty {
                shelfItems
                    .padding(.horizontal, 6)
            }

            marqueeEdgeZones
                .allowsHitTesting(!workspaceState.isShelfDropTargeted)

            if workspaceState.isShelfDropTargeted, store.items.isEmpty {
                dropPrompt
                    .frame(
                        width: size.width,
                        height: size.height,
                        alignment: .center
                    )
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
        .onPreferenceChange(FileShelfItemFramePreferenceKey.self) { frames in
            Task { @MainActor in
                itemFrames = frames
            }
        }
        .onChange(of: store.items.map(\.id)) { _, itemIDs in
            selection.retainValidIDs(Set(itemIDs))
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
        .onDisappear {
            cancelMarqueeSelection()
            previewController.close()
        }
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
                        isSelected: selection.selectedIDs.contains(item.id),
                        onSelect: { modifiers in
                            selectForMouseDown(item.id, modifiers: modifiers)
                        },
                        onSelectExclusive: {
                            selection.selectExclusively(item.id)
                        },
                        dragURLs: {
                            selectedURLs(startingAt: item.id)
                        },
                        onSelectAll: selectAllItems,
                        onPreview: {
                            previewSelection(preferredID: item.id)
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
                    selectionAtDragStart = selection.selectedIDs
                    keyboardFocusGeneration += 1
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
                selection.applyMarquee(
                    enclosedIDs: enclosedIDs,
                    initialSelection: selectionAtDragStart,
                    modifiers: NSEvent.modifierFlags
                )
                selectionRect = rect
            }
            .onEnded { _ in
                selectionRect = nil
                selectionAtDragStart = []
            }
    }

    private func selectForMouseDown(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        cancelMarqueeSelection()
        selection.selectForMouseDown(
            id,
            orderedIDs: store.items.map(\.id),
            modifiers: modifiers
        )
    }

    private func selectAllItems() {
        selection.selectAll(store.items.map(\.id))
    }

    private func removeSelectedItems() {
        guard !selection.isEmpty else { return }
        store.remove(ids: selection.selectedIDs)
        selection.clear()
        previewController.close()
    }

    private func selectedURLs(startingAt id: UUID? = nil) -> [URL] {
        let selectedIDs = selection.orderedSelection(
            from: store.items.map(\.id),
            startingAt: id
        )
        let itemByID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })

        return selectedIDs.compactMap { id in
            guard let item = itemByID[id], store.isAvailable(item) else { return nil }
            return store.resolvedURL(for: item)
        }
    }

    private func previewSelection(preferredID: UUID? = nil) {
        let urls = selectedURLs(startingAt: preferredID)
        guard !urls.isEmpty else { return }

        let preferredURL = preferredID.flatMap { id in
            store.items.first(where: { $0.id == id }).flatMap(store.resolvedURL)
        }
        previewController.toggle(urls: urls, preferredURL: preferredURL) { isVisible in
            workspaceState.isPreviewingShelfItem = isVisible
        }
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
    let onSelectExclusive: () -> Void
    let dragURLs: () -> [URL]
    let onSelectAll: () -> Void
    let onPreview: () -> Void
    let onDeleteSelected: () -> Void
    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        draggableChip
            .task(id: item.fallbackPath) {
                await store.refreshAvailability(item)
            }
            .task(id: thumbnailTaskID) {
                thumbnail = nil
                guard let url, isAvailable, isImage else { return }
                let loadedThumbnail = await FileShelfThumbnailLoader.thumbnail(for: url)
                guard !Task.isCancelled else { return }
                thumbnail = loadedThumbnail
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
                        dragURLs: dragURLs,
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
                        onSelectExclusive: onSelectExclusive,
                        onSelectAll: onSelectAll,
                        onPreview: onPreview,
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
                    fileIdentityImage

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
                ? "\(displayName) · \(fileKind) · Press Space to preview"
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
        return effectiveFileExtension?.uppercased() ?? "File"
    }

    @ViewBuilder
    private var fileIdentityImage: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            Image(nsImage: fileIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .opacity(isAvailable ? 1 : 0.34)
        }
    }

    private var isImage: Bool {
        guard item.isDirectory != true,
              let fileExtension = effectiveFileExtension,
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private var effectiveFileExtension: String? {
        if let fileExtension = item.fileExtension, !fileExtension.isEmpty {
            return fileExtension
        }
        guard let pathExtension = url?.pathExtension, !pathExtension.isEmpty else { return nil }
        return pathExtension
    }

    private var thumbnailTaskID: String {
        "\(item.fallbackPath)|\(isAvailable)|\(isImage)"
    }

    private var fileIcon: NSImage {
        let contentType: UTType
        if item.isDirectory == true {
            contentType = .folder
        } else if let fileExtension = effectiveFileExtension,
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
    let dragURLs: () -> [URL]
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let onHoverChange: (Bool) -> Void
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onSelectExclusive: () -> Void
    let onSelectAll: () -> Void
    let onPreview: () -> Void
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
        nsView.dragURLs = dragURLs
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.onHoverChange = onHoverChange
        nsView.onSelect = onSelect
        nsView.onSelectExclusive = onSelectExclusive
        nsView.onSelectAll = onSelectAll
        nsView.onPreview = onPreview
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
    var dragURLs: (() -> [URL])?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onSelectExclusive: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onPreview: (() -> Void)?
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
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectAll?()
        } else if event.keyCode == 49 {
            onPreview?()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelected?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !didStartDrag,
              let mouseDownLocation,
              FileDragGesturePolicy.shouldBegin(from: mouseDownLocation, to: location),
              let url else {
            return
        }
        let urls = dragURLs?() ?? [url]
        guard !urls.isEmpty else { return }
        didStartDrag = true
        onHoverChange?(false)
        onDragBegan?()

        let draggingItems = urls.enumerated().map { index, draggedURL in
            let icon = NSWorkspace.shared.icon(forFile: draggedURL.path)
            icon.size = NSSize(width: 44, height: 44)
            let offset = CGFloat(min(index, 3)) * 3
            let draggingItem = NSDraggingItem(
                pasteboardWriter: FileDragPasteboard.writer(for: draggedURL)
            )
            draggingItem.setDraggingFrame(
                NSRect(
                    x: location.x - 22 + offset,
                    y: location.y - 22 - offset,
                    width: 44,
                    height: 44
                ),
                contents: icon
            )
            return draggingItem
        }

        let session = beginDraggingSession(
            with: draggingItems,
            event: event,
            source: self
        )
        if draggingItems.count > 1 {
            session.draggingFormation = .stack
        }
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !didStartDrag else { return }
        if event.modifierFlags.intersection([.command, .shift]).isEmpty {
            onSelectExclusive?()
        }
        if event.clickCount == 2 {
            onOpen?()
        }
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

private struct FileShelfKeyboardFocusView: NSViewRepresentable {
    let focusGeneration: Int
    let onSelectAll: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> FileShelfKeyboardNSView {
        FileShelfKeyboardNSView()
    }

    func updateNSView(_ nsView: FileShelfKeyboardNSView, context: Context) {
        nsView.onSelectAll = onSelectAll
        nsView.onPreview = onPreview
        nsView.onDelete = onDelete

        guard nsView.focusGeneration != focusGeneration else { return }
        nsView.focusGeneration = focusGeneration
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

@MainActor
private final class FileShelfKeyboardNSView: NSView {
    var focusGeneration = 0
    var onSelectAll: (() -> Void)?
    var onPreview: (() -> Void)?
    var onDelete: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectAll?()
        } else if event.keyCode == 49 {
            onPreview?()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }
}

@MainActor
private final class FileShelfPreviewController: NSObject, ObservableObject,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []
    private var onVisibilityChanged: ((Bool) -> Void)?

    func toggle(
        urls: [URL],
        preferredURL: URL?,
        onVisibilityChanged: @escaping (Bool) -> Void
    ) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, panel.dataSource === self {
            close()
            return
        }

        self.urls = urls
        self.onVisibilityChanged = onVisibilityChanged
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if let preferredURL, let index = urls.firstIndex(of: preferredURL) {
            panel.currentPreviewItemIndex = index
        } else {
            panel.currentPreviewItemIndex = 0
        }
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChanged(true)
    }

    func close() {
        guard let panel = QLPreviewPanel.shared(), panel.dataSource === self else {
            onVisibilityChanged?(false)
            return
        }
        panel.orderOut(nil)
        onVisibilityChanged?(false)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        onVisibilityChanged?(false)
    }
}

@MainActor
private enum FileShelfThumbnailLoader {
    static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 96, height: 72),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
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
