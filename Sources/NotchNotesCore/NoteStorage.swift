import Darwin
import Foundation

public struct NoteTab: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var selectionLocation: Int?
    public var selectionLength: Int?

    public init(
        id: UUID = UUID(),
        text: String = "",
        createdAt: Date = Date(),
        selectionLocation: Int? = 0,
        selectionLength: Int? = 0
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
    }
}

public struct PersistedNotes: Codable, Equatable, Sendable {
    public var tabs: [NoteTab]
    public var activeTabID: UUID
    public var savedAt: Date

    public init(tabs: [NoteTab], activeTabID: UUID, savedAt: Date) {
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.savedAt = savedAt
    }
}

public struct FileShelfItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let bookmarkData: Data?
    public let fallbackPath: String
    public let originalName: String
    public let addedAt: Date
    public let isDirectory: Bool?
    public let fileExtension: String?

    public init(url: URL) {
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

public enum NoteStorageError: LocalizedError, Equatable, Sendable {
    case targetNotFound(String)
    case ambiguousTarget(String, [String])
    case cannotDeleteLastNote
    case emptySearchQuery
    case shelfItemNotFound(String)
    case fileNotFound(String)
    case lockFailed(String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .targetNotFound(target):
            return "Note not found: '\(target)'."
        case let .ambiguousTarget(target, candidates):
            return "Ambiguous note target '\(target)'. Matches: \(candidates.joined(separator: ", "))."
        case .cannotDeleteLastNote:
            return "Cannot delete the last remaining note."
        case .emptySearchQuery:
            return "Search query must not be empty."
        case let .shelfItemNotFound(target):
            return "Shelf item not found: '\(target)'."
        case let .fileNotFound(path):
            return "File not found: '\(path)'."
        case let .lockFailed(reason):
            return "Failed to acquire notes lock: \(reason)"
        case let .persistenceFailed(reason):
            return "Failed to save notes: \(reason)"
        }
    }
}

public enum NoteTargetMatcher {
    public static func resolveIndex(in tabs: [NoteTab], activeTabID: UUID, target: String?) throws -> Int {
        guard !tabs.isEmpty else {
            throw NoteStorageError.targetNotFound(target ?? "--active")
        }

        guard let rawTarget = target else {
            return tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        }

        if let uuid = UUID(uuidString: rawTarget),
           let exactIndex = tabs.firstIndex(where: { $0.id == uuid }) {
            return exactIndex
        }

        if let oneBased = Int(rawTarget) {
            if (1...tabs.count).contains(oneBased) {
                return oneBased - 1
            }
            let titles = tabs.enumerated().map { idx, tab in
                NoteTitleExtractor.title(for: tab.text, index: idx)
            }
            let exactNumericMatches = titles.enumerated().filter { $0.element == rawTarget }.map(\.offset)
            if exactNumericMatches.count == 1 {
                return exactNumericMatches[0]
            } else if exactNumericMatches.count > 1 {
                throw NoteStorageError.ambiguousTarget(
                    rawTarget,
                    exactNumericMatches.map { "#\($0 + 1) \(titles[$0]) (\(tabs[$0].id.uuidString.prefix(8)))" }
                )
            }
            throw NoteStorageError.targetNotFound(rawTarget)
        }

        let titles = tabs.enumerated().map { idx, tab in
            NoteTitleExtractor.title(for: tab.text, index: idx)
        }

        let exactCaseMatches = titles.enumerated().filter { $0.element == rawTarget }.map(\.offset)
        if exactCaseMatches.count == 1 {
            return exactCaseMatches[0]
        } else if exactCaseMatches.count > 1 {
            throw NoteStorageError.ambiguousTarget(
                rawTarget,
                exactCaseMatches.map { "#\($0 + 1) \(titles[$0]) (\(tabs[$0].id.uuidString.prefix(8)))" }
            )
        }

        let exactFoldedMatches = titles.enumerated().filter {
            $0.element.caseInsensitiveCompare(rawTarget) == .orderedSame
        }.map(\.offset)
        if exactFoldedMatches.count == 1 {
            return exactFoldedMatches[0]
        } else if exactFoldedMatches.count > 1 {
            throw NoteStorageError.ambiguousTarget(
                rawTarget,
                exactFoldedMatches.map { "#\($0 + 1) \(titles[$0]) (\(tabs[$0].id.uuidString.prefix(8)))" }
            )
        }

        if rawTarget.count >= 4, rawTarget.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let lowered = rawTarget.lowercased()
            let uuidPrefixMatches = tabs.enumerated().filter {
                $0.element.id.uuidString.lowercased().hasPrefix(lowered)
            }.map(\.offset)
            if uuidPrefixMatches.count == 1 {
                return uuidPrefixMatches[0]
            } else if uuidPrefixMatches.count > 1 {
                throw NoteStorageError.ambiguousTarget(
                    rawTarget,
                    uuidPrefixMatches.map { "#\($0 + 1) \(titles[$0]) (\(tabs[$0].id.uuidString.prefix(8)))" }
                )
            }
        }

        let prefixCaseMatches = titles.enumerated().filter { $0.element.hasPrefix(rawTarget) }.map(\.offset)
        if prefixCaseMatches.count == 1 {
            return prefixCaseMatches[0]
        } else if prefixCaseMatches.count > 1 {
            throw NoteStorageError.ambiguousTarget(
                rawTarget,
                prefixCaseMatches.map { "#\($0 + 1) \(titles[$0]) (\(tabs[$0].id.uuidString.prefix(8)))" }
            )
        }

        let loweredTarget = rawTarget.lowercased()
        let prefixFoldedMatches = titles.enumerated().filter {
            $0.element.lowercased().hasPrefix(loweredTarget)
        }.map(\.offset)
        if prefixFoldedMatches.count == 1 {
            return prefixFoldedMatches[0]
        } else if prefixFoldedMatches.count > 1 {
            throw NoteStorageError.ambiguousTarget(
                rawTarget,
                prefixFoldedMatches.map { "#\($0 + 1) \(titles[$0]) (\(tabs[$0].id.uuidString.prefix(8)))" }
            )
        }

        throw NoteStorageError.targetNotFound(rawTarget)
    }
}

public enum NoteStorage {
    public static let appBundleIdentifier = "io.github.oiloil.NotchNotes"
    public static let legacyTextKey = "notchNotes.text"
    public static let tabsKey = "notchNotes.tabs.v1"
    public static let archiveDefaultsKey = "notchNotes.archive.v2"
    public static let activeTabIDKey = "notchNotes.activeTabID"
    public static let lastSavedAtKey = "notchNotes.lastSavedAt"
    public static let fileShelfKey = "notchNotes.fileShelf.v1"
    public static let maximumShelfItemCount = 100

    public static let dataDirEnvKey = "NOTCHNOTES_DATA_DIR"
    public static let defaultsSuiteEnvKey = "NOTCHNOTES_DEFAULTS_SUITE"

    public static func defaultDataDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let customDir = environment[dataDirEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customDir.isEmpty {
            let expanded = (customDir as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("NotchNotes", isDirectory: true)
    }

    public static func defaultArchiveURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        defaultDataDirectoryURL(environment: environment)?
            .appendingPathComponent("notes.json")
    }

    public static func lockFileURL(for archiveURL: URL) -> URL {
        archiveURL.deletingLastPathComponent().appendingPathComponent("notes.lock")
    }

    public static func resolveUserDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        if let customSuite = environment[defaultsSuiteEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customSuite.isEmpty {
            if Bundle.main.bundleIdentifier == customSuite {
                return .standard
            }
            return UserDefaults(suiteName: customSuite) ?? .standard
        }

        if Bundle.main.bundleIdentifier == appBundleIdentifier {
            return .standard
        }

        return UserDefaults(suiteName: appBundleIdentifier) ?? .standard
    }

    public static func loadInitialState(
        defaults: UserDefaults,
        archiveURL: URL?
    ) -> (tabs: [NoteTab], activeTabID: UUID) {
        let snapshot = loadLatestSnapshot(defaults: defaults, archiveURL: archiveURL)
        let storedTabs = snapshot?.tabs ?? []
        let initialTabs: [NoteTab]

        if storedTabs.isEmpty {
            let legacyText = defaults.string(forKey: legacyTextKey) ?? ""
            initialTabs = [NoteTab(text: legacyText)]
        } else {
            initialTabs = storedTabs
        }

        let activeIDString = defaults.string(forKey: activeTabIDKey)
        let storedActiveID = activeIDString.flatMap(UUID.init(uuidString:))
        let preferredActiveID = snapshot?.activeTabID ?? storedActiveID
        let activeTabID = preferredActiveID.flatMap { activeID in
            initialTabs.contains(where: { $0.id == activeID }) ? activeID : nil
        } ?? initialTabs[0].id

        return (initialTabs, activeTabID)
    }

    public static func loadLatestSnapshot(
        defaults: UserDefaults,
        archiveURL: URL?
    ) -> PersistedNotes? {
        let archiveSnapshot: PersistedNotes? = archiveURL.flatMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PersistedNotes.self, from: data)
        }

        let defaultsSnapshot: PersistedNotes? = {
            if let data = defaults.data(forKey: archiveDefaultsKey),
               let snapshot = try? JSONDecoder().decode(PersistedNotes.self, from: data),
               !snapshot.tabs.isEmpty {
                return snapshot
            }

            guard let data = defaults.data(forKey: tabsKey),
                  let tabs = try? JSONDecoder().decode([NoteTab].self, from: data),
                  !tabs.isEmpty else {
                return nil
            }

            let storedActiveID = defaults.string(forKey: activeTabIDKey)
                .flatMap(UUID.init(uuidString:))
            let activeID = storedActiveID.flatMap { candidate in
                tabs.contains(where: { $0.id == candidate }) ? candidate : nil
            } ?? tabs[0].id
            let savedAt = defaults.object(forKey: lastSavedAtKey) as? Date ?? .distantPast
            return PersistedNotes(tabs: tabs, activeTabID: activeID, savedAt: savedAt)
        }()

        switch (defaultsSnapshot, archiveSnapshot) {
        case let (defaultsSnapshot?, archiveSnapshot?):
            return defaultsSnapshot.savedAt >= archiveSnapshot.savedAt
                ? defaultsSnapshot
                : archiveSnapshot
        case let (defaultsSnapshot?, nil):
            return defaultsSnapshot
        case let (nil, archiveSnapshot?):
            return archiveSnapshot
        case (nil, nil):
            return nil
        }
    }

    public static func writeDefaultsSnapshot(
        _ snapshot: PersistedNotes,
        archiveData: Data,
        defaults: UserDefaults,
        synchronize: Bool = false
    ) {
        let activeText = snapshot.tabs.first(where: { $0.id == snapshot.activeTabID })?.text
            ?? snapshot.tabs.first?.text
            ?? ""
        defaults.set(archiveData, forKey: archiveDefaultsKey)
        defaults.set(snapshot.activeTabID.uuidString, forKey: activeTabIDKey)
        defaults.set(activeText, forKey: legacyTextKey)
        defaults.set(snapshot.savedAt, forKey: lastSavedAtKey)
        if synchronize {
            _ = defaults.synchronize()
        }
    }

    public static func writeArchiveFileLocked(
        _ archiveData: Data,
        to archiveURL: URL
    ) throws {
        try withExclusiveFileLock(for: archiveURL) {
            try archiveData.write(to: archiveURL, options: .atomic)
        }
    }

    public static func withExclusiveFileLock<T>(
        for archiveURL: URL,
        body: () throws -> T
    ) throws -> T {
        let directoryURL = archiveURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = lockFileURL(for: archiveURL)
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw NoteStorageError.lockFailed(reason)
        }
        defer {
            _ = flock(fd, LOCK_UN)
            _ = Darwin.close(fd)
        }

        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR {
                continue
            }
            let reason = String(cString: strerror(errno))
            throw NoteStorageError.lockFailed(reason)
        }

        return try body()
    }

    public static func clampedSelection(location: Int?, length: Int?, for text: String) -> (Int, Int) {
        let utf16Length = (text as NSString).length
        let clampedLoc = min(max(location ?? 0, 0), utf16Length)
        let clampedLen = min(max(length ?? 0, 0), utf16Length - clampedLoc)
        return (clampedLoc, clampedLen)
    }

    public static func loadShelfItems(from defaults: UserDefaults) -> [FileShelfItem] {
        guard let data = defaults.data(forKey: fileShelfKey),
              let items = try? JSONDecoder().decode([FileShelfItem].self, from: data) else {
            return []
        }
        return items
    }

    public static func saveShelfItems(
        _ items: [FileShelfItem],
        to defaults: UserDefaults,
        synchronize: Bool = false
    ) throws {
        let data = try JSONEncoder().encode(items)
        defaults.set(data, forKey: fileShelfKey)
        if synchronize {
            _ = defaults.synchronize()
        }
    }

    public static func resolveShelfRemovalIDs(in items: [FileShelfItem], target: String) throws -> Set<UUID> {
        if let uuid = UUID(uuidString: target),
           items.contains(where: { $0.id == uuid }) {
            return [uuid]
        }

        let standardizedCandidate = URL(fileURLWithPath: target).standardizedFileURL.path
        let pathMatches = items.filter {
            URL(fileURLWithPath: $0.fallbackPath).standardizedFileURL.path == standardizedCandidate
                || $0.fallbackPath == target
        }
        if !pathMatches.isEmpty {
            return Set(pathMatches.map(\.id))
        }

        if target.count >= 4, target.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let lowered = target.lowercased()
            let prefixMatches = items.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
            if prefixMatches.count == 1 {
                return [prefixMatches[0].id]
            }
        }

        let nameMatches = items.filter { $0.originalName == target }
        if nameMatches.count == 1 {
            return [nameMatches[0].id]
        }

        throw NoteStorageError.shelfItemNotFound(target)
    }
}
