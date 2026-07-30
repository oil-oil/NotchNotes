import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

            Text("Original files stay on disk")
        }
    }

    private var dropPrompt: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))

            Text("Drop to shelf")
                .font(.system(size: 11, weight: .semibold))

            Text("Originals stay put")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.075)))
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
            .contextMenu {
                Button("Open") {
                    open()
                }
                .disabled(!isAvailable)

                Button("Show in Finder") {
                    revealInFinder()
                }
                .disabled(!isAvailable)

                Divider()

                Button("Remove from Shelf") {
                    removeFromShelf()
                }
            }
    }

    @ViewBuilder
    private var draggableChip: some View {
        if let url, isAvailable {
            chip
                .onDrag {
                    workspaceState.isDraggingShelfItem = true
                    return NSItemProvider(contentsOf: url)
                        ?? NSItemProvider(object: url as NSURL)
                } preview: {
                    dragPreview
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
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
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
        .onTapGesture(count: 2, perform: open)
        .help(isAvailable ? "\(displayName) · \(fileKind)" : "\(displayName) is unavailable")
        .accessibilityLabel(displayName)
    }

    private var dragPreview: some View {
        VStack(spacing: 4) {
            Image(nsImage: fileIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)

            Text(displayName)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 70)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
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
