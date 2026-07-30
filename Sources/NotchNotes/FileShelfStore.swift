import Combine
import Foundation

@MainActor
final class NotebookWorkspaceState: ObservableObject {
    @Published var isShelfDropTargeted = false
    @Published var isDraggingShelfItem = false
}

struct FileShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let bookmarkData: Data?
    let fallbackPath: String
    let originalName: String
    let addedAt: Date
    let isDirectory: Bool?
    let fileExtension: String?

    init(url: URL) {
        id = UUID()
        // File bookmarks can block the main thread when they are created
        // synchronously inside AppKit's drop callback. The shelf is temporary,
        // so keeping the normalized path is sufficient and avoids that stall.
        bookmarkData = nil
        fallbackPath = url.standardizedFileURL.path
        originalName = url.lastPathComponent
        addedAt = Date()
        isDirectory = url.hasDirectoryPath
        fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension
    }
}

@MainActor
final class FileShelfStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem]
    @Published private var availabilityByID: [UUID: Bool] = [:]

    private static let storageKey = "notchNotes.fileShelf.v1"
    private static let maximumItemCount = 100
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.load(from: defaults)
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let existingPaths = Set(items.compactMap { resolvedURL(for: $0)?.standardizedFileURL.path })
        var knownPaths = existingPaths
        var addedItems: [FileShelfItem] = []

        for url in urls where url.isFileURL {
            guard items.count + addedItems.count < Self.maximumItemCount else { break }
            let standardizedURL = url.standardizedFileURL
            guard knownPaths.insert(standardizedURL.path).inserted else { continue }
            addedItems.append(FileShelfItem(url: standardizedURL))
        }

        guard !addedItems.isEmpty else { return 0 }
        items.append(contentsOf: addedItems)
        save()
        return addedItems.count
    }

    func remove(_ item: FileShelfItem) {
        items.removeAll { $0.id == item.id }
        availabilityByID[item.id] = nil
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
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [FileShelfItem] {
        guard let data = defaults.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([FileShelfItem].self, from: data) else {
            return []
        }

        return items
    }
}
