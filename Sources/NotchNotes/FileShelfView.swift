import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private enum FilePreviewImageProvider {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage {
        let standardizedURL = url.standardizedFileURL
        let cacheKey = standardizedURL as NSURL
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        let image: NSImage
        if isImageFile(standardizedURL),
           let contentImage = NSImage(contentsOf: standardizedURL) {
            image = contentImage
        } else {
            image = NSWorkspace.shared.icon(forFile: standardizedURL.path)
        }

        cache.setObject(image, forKey: cacheKey)
        return image
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath,
              let contentType = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return contentType.conforms(to: .image)
    }
}

struct FileShelfView: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    let size: CGSize

    var body: some View {
        ZStack {
            if !store.items.isEmpty {
                HStack(spacing: 4) {
                    shelfLabel
                    shelfItems
                }
                .padding(.horizontal, 8)
                .opacity(workspaceState.isShelfDropTargeted ? 0.16 : 1)
                .scaleEffect(workspaceState.isShelfDropTargeted ? 0.985 : 1)
            }

            if workspaceState.isShelfDropTargeted {
                dropPrompt
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(workspaceState.isShelfDropTargeted ? 0.055 : 0.025))
        )
        .shadow(
            color: .black.opacity(workspaceState.isShelfDropTargeted ? 0.24 : 0),
            radius: 18,
            y: 8
        )
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: workspaceState.isShelfDropTargeted)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.items)
    }

    private var shelfLabel: some View {
        ZStack {
            Image(systemName: "folder.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white.opacity(0.13))

            Text("\(store.items.count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .offset(y: 2)
        }
        .frame(width: 42, height: 54)
        .help("\(store.items.count) item\(store.items.count == 1 ? "" : "s") on the shelf")
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    store.removeAll()
                }
            } label: {
                Label("Remove All Shelf Items", systemImage: "xmark.circle")
            }

            Text("Drop: Copy · ⌘ Drop: Cut")
        }
    }

    private var dropPrompt: some View {
        HStack(spacing: 9) {
            if workspaceState.draggedFileURLs.isEmpty {
                Image(systemName: workspaceState.shelfDropOperation.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            } else {
                FileDropPreviewStack(urls: workspaceState.draggedFileURLs)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(workspaceState.shelfDropOperation == .cut ? "Cut to shelf" : "Copy to shelf")
                    .font(.system(size: 11, weight: .semibold))

                Text(dropPreviewDetail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 250, alignment: .leading)
        }
        .foregroundStyle(
            workspaceState.shelfDropOperation == .cut
                ? Color.orange.opacity(0.88)
                : Color.white.opacity(0.82)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.075)))
        .animation(.easeOut(duration: 0.12), value: workspaceState.shelfDropOperation)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: workspaceState.draggedFileURLs)
    }

    private var dropPreviewDetail: String {
        let instruction = workspaceState.shelfDropOperation == .cut
            ? "Release ⌘ to copy"
            : "Hold ⌘ to cut"

        switch workspaceState.draggedFileURLs.count {
        case 0:
            return instruction
        case 1:
            return "\(workspaceState.draggedFileURLs[0].lastPathComponent) · \(instruction)"
        default:
            return "\(workspaceState.draggedFileURLs.count) files · \(instruction)"
        }
    }

    private var shelfItems: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 2) {
                ForEach(store.items) { item in
                    FileShelfChip(
                        item: item,
                        store: store,
                        workspaceState: workspaceState
                    )
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92))
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct FileDropPreviewStack: View {
    let urls: [URL]

    var body: some View {
        ZStack {
            ForEach(Array(visibleURLs.enumerated()), id: \.offset) { index, url in
                FileDropPreviewCard(url: url)
                    .rotationEffect(.degrees(rotation(for: index)))
                    .offset(x: horizontalOffset(for: index), y: verticalOffset(for: index))
                    .zIndex(Double(index))
            }

            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(Color.black.opacity(0.82)))
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                    .offset(x: 19, y: 14)
                    .zIndex(4)
            }
        }
        .frame(width: 56, height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(urls.count) dragged file\(urls.count == 1 ? "" : "s")")
    }

    private var visibleURLs: [URL] {
        Array(urls.prefix(3))
    }

    private var hiddenCount: Int {
        max(urls.count - visibleURLs.count, 0)
    }

    private func rotation(for index: Int) -> Double {
        let rotations = [-7.0, 0, 7.0]
        return rotations[min(index, rotations.count - 1)]
    }

    private func horizontalOffset(for index: Int) -> CGFloat {
        let offsets: [CGFloat] = [-7, 0, 7]
        return offsets[min(index, offsets.count - 1)]
    }

    private func verticalOffset(for index: Int) -> CGFloat {
        CGFloat(index - 1) * -1.5
    }
}

private struct FileDropPreviewCard: View {
    let url: URL

    var body: some View {
        Group {
            if isImageFile {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipped()
            } else {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .frame(width: 36, height: 36)
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.115))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 5, y: 3)
        .accessibilityHidden(true)
    }

    private var previewImage: NSImage {
        FilePreviewImageProvider.image(for: url)
    }

    private var isImageFile: Bool {
        FilePreviewImageProvider.isImageFile(url)
    }
}

private struct FileShelfChip: View {
    let item: FileShelfItem
    @ObservedObject var store: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
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
                        transferOperation: transferOperation,
                        onDragBegan: {
                            workspaceState.isDraggingShelfItem = true
                        },
                        onDragEnded: {
                            workspaceState.isDraggingShelfItem = false
                        },
                        onMoveCompleted: removeFromShelf,
                        onOpen: open,
                        onReveal: revealInFinder,
                        onRemove: removeFromShelf,
                        onSetTransferOperation: { operation in
                            store.setTransferOperation(operation, for: item)
                        }
                    )
                }
        } else {
            chip
        }
    }

    private var chip: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: fileIcon)
                        .resizable()
                        .aspectRatio(contentMode: isImageFile ? .fill : .fit)
                        .frame(width: 30, height: 30)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: isImageFile ? 5 : 0,
                                style: .continuous
                            )
                        )
                        .opacity(isAvailable ? 1 : 0.34)

                    if isAvailable {
                        transferBadge
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.72))
                            .background(Circle().fill(Color.black))
                    }
                }

                Text(displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(isAvailable ? 0.66 : 0.34))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 58)
            }
            .frame(width: 66, height: 58)

            if isHovering {
                Button {
                    removeFromShelf()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(ShelfRemoveButtonStyle())
                .help("Remove from shelf (file stays on disk)")
                .offset(x: 1, y: -1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.065 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .scaleEffect(isHovering ? 1.025 : 1)
        .offset(y: isHovering ? -1 : 0)
        .shadow(color: .black.opacity(isHovering ? 0.20 : 0), radius: 8, y: 4)
        .animation(.spring(response: 0.20, dampingFraction: 0.82), value: isHovering)
        .onHover { isHovering = $0 }
        .help(
            isAvailable
                ? "\(displayName) · \(fileKind) · \(transferOperation.title)"
                : "\(displayName) is unavailable"
        )
        .accessibilityLabel(displayName)
    }

    private var transferBadge: some View {
        Image(systemName: transferOperation.systemImage)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(
                transferOperation == .cut
                    ? Color.orange.opacity(0.94)
                    : Color.cyan.opacity(0.82)
            )
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.black.opacity(0.78)))
            .offset(x: 3, y: 3)
    }

    private var url: URL? {
        store.resolvedURL(for: item)
    }

    private var isAvailable: Bool {
        store.isAvailable(item)
    }

    private var transferOperation: FileShelfTransferOperation {
        item.effectiveTransferOperation
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
        guard let url, isAvailable else {
            return NSWorkspace.shared.icon(for: .data)
        }
        return FilePreviewImageProvider.image(for: url)
    }

    private var isImageFile: Bool {
        guard let url, isAvailable else { return false }
        return FilePreviewImageProvider.isImageFile(url)
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
    let transferOperation: FileShelfTransferOperation
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let onMoveCompleted: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onSetTransferOperation: (FileShelfTransferOperation) -> Void

    func makeNSView(context: Context) -> FileDragSourceNSView {
        FileDragSourceNSView()
    }

    func updateNSView(_ nsView: FileDragSourceNSView, context: Context) {
        nsView.url = url
        nsView.displayName = displayName
        nsView.transferOperation = transferOperation
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.onMoveCompleted = onMoveCompleted
        nsView.onOpen = onOpen
        nsView.onReveal = onReveal
        nsView.onRemove = onRemove
        nsView.onSetTransferOperation = onSetTransferOperation
    }
}

@MainActor
private final class FileDragSourceNSView: NSView, NSDraggingSource {
    var url: URL?
    var displayName = ""
    var transferOperation: FileShelfTransferOperation = .copy
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onMoveCompleted: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?
    var onSetTransferOperation: ((FileShelfTransferOperation) -> Void)?

    private var didStartDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let url else { return }
        didStartDrag = true
        onDragBegan?()

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 44, height: 44)

        let location = convert(event.locationInWindow, from: nil)
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
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
        guard !didStartDrag, event.clickCount == 2 else { return }
        onOpen?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        menu.addItem(menuItem(title: "Open", action: #selector(openItem)))
        menu.addItem(menuItem(title: "Show in Finder", action: #selector(revealItem)))
        menu.addItem(.separator())

        let copyItem = menuItem(title: "Copy", action: #selector(setCopyOperation))
        copyItem.state = transferOperation == .copy ? .on : .off
        menu.addItem(copyItem)

        let cutItem = menuItem(title: "Cut", action: #selector(setCutOperation))
        cutItem.state = transferOperation == .cut ? .on : .off
        menu.addItem(cutItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Remove from Shelf", action: #selector(removeItem)))
        return menu
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        transferOperation == .cut ? .move : .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?()

        guard transferOperation == .cut,
              operation.contains(.move),
              let url else {
            didStartDrag = false
            return
        }

        onMoveCompleted?()
        didStartDrag = false

        Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try? FileManager.default.removeItem(at: url)
        }
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

    @objc private func setCopyOperation() {
        onSetTransferOperation?(.copy)
    }

    @objc private func setCutOperation() {
        onSetTransferOperation?(.cut)
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
