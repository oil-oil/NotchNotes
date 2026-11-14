import Combine
import Foundation
@_exported import NotchNotesCore

@MainActor
final class NotebookWorkspaceState: ObservableObject {
    @Published var isShelfDropTargeted = false
    @Published var isDraggingShelfItem = false
    @Published var isPreviewingShelfItem = false
}

@MainActor
final class FileShelfStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem]
    @Published private var availabilityByID: [UUID: Bool] = [:]

    private static let maximumItemCount = NoteStorage.maximumShelfItemCount
    private let defaults: UserDefaults

    init(defaults: UserDefaults = NoteStorage.resolveUserDefaults()) {
        self.defaults = defaults
        items = NoteStorage.loadShelfItems(from: defaults)
    }

    @discardableResult
    func acceptDrop(_ urls: [URL]) -> Bool {
        let fileURLs = FileDropPayload.normalizedFileURLs(from: urls)
        guard !fileURLs.isEmpty else { return false }

        _ = add(fileURLs)
        return true
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let existingPaths = Set(items.compactMap { resolvedURL(for: $0)?.standardizedFileURL.path })
        var knownPaths = existingPaths
        var addedItems: [FileShelfItem] = []

        for url in urls where url.isFileURL {
            let standardizedURL = url.standardizedFileURL

            if items.contains(where: {
                resolvedURL(for: $0)?.standardizedFileURL.path == standardizedURL.path
            }) {
                continue
            }

            guard items.count + addedItems.count < Self.maximumItemCount else { break }
            guard knownPaths.insert(standardizedURL.path).inserted else { continue }
            addedItems.append(FileShelfItem(url: standardizedURL))
        }

        guard !addedItems.isEmpty else { return 0 }
        items.append(contentsOf: addedItems)
        save()
        return addedItems.count
    }

    func remove(_ item: FileShelfItem) {
        remove(ids: [item.id])
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            availabilityByID[id] = nil
        }
        save()
    }

    func removeAll() {
        items.removeAll()
        availabilityByID.removeAll()
        save()
    }

    func resolvedURL(for item: FileShelfItem) -> URL? {
        URL(fileURLWithPath: item.fallbackPath).standardizedFileURL
    }

    func isAvailable(_ item: FileShelfItem) -> Bool {
        availabilityByID[item.id] ?? true
    }

    func refreshAvailability(_ item: FileShelfItem) async {
        let path = item.fallbackPath
        let isAvailable = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value

        guard items.contains(where: { $0.id == item.id }) else { return }
        availabilityByID[item.id] = isAvailable
    }

    private func save() {
        try? NoteStorage.saveShelfItems(items, to: defaults)
    }
}
