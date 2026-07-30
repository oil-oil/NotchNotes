import Combine
import Foundation

struct NoteTab: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var selectionLocation: Int?
    var selectionLength: Int?

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        selectionLocation = 0
        selectionLength = 0
    }
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var tabs: [NoteTab]
    @Published private(set) var activeTabID: UUID

    private static let legacyTextKey = "notchNotes.text"
    private static let tabsKey = "notchNotes.tabs.v1"
    private static let archiveDefaultsKey = "notchNotes.archive.v2"
    private static let activeTabIDKey = "notchNotes.activeTabID"
    private static let lastSavedAtKey = "notchNotes.lastSavedAt"
    private static let saveDelay: TimeInterval = 0.18

    private struct PersistedNotes: Codable {
        let tabs: [NoteTab]
        let activeTabID: UUID
        let savedAt: Date
    }

    private struct DeletedNote {
        let tab: NoteTab
        let index: Int
    }

    private let defaults: UserDefaults
    private let archiveURL: URL?
    private let persistenceQueue = DispatchQueue(label: "io.github.oiloil.NotchNotes.persistence")
    private var pendingSave: DispatchWorkItem?
    private var recentlyDeletedNote: DeletedNote?

    init(
        defaults: UserDefaults = .standard,
        archiveURL: URL? = NoteStore.defaultArchiveURL()
    ) {
        self.defaults = defaults
        self.archiveURL = archiveURL

        let snapshot = Self.loadLatestSnapshot(defaults: defaults, archiveURL: archiveURL)
        let storedTabs = snapshot?.tabs ?? []
        let initialTabs: [NoteTab]

        if storedTabs.isEmpty {
            let legacyText = defaults.string(forKey: Self.legacyTextKey) ?? ""
            initialTabs = [NoteTab(text: legacyText)]
        } else {
            initialTabs = storedTabs
        }

        tabs = initialTabs

        let activeIDString = defaults.string(forKey: Self.activeTabIDKey)
        let storedActiveID = activeIDString.flatMap(UUID.init(uuidString:))
        let preferredActiveID = snapshot?.activeTabID ?? storedActiveID
        activeTabID = preferredActiveID.flatMap { activeID in
            initialTabs.contains(where: { $0.id == activeID }) ? activeID : nil
        } ?? initialTabs[0].id

        persistNow()
    }

    var text: String {
        tabs[activeIndex].text
    }

    func updateText(_ nextText: String) {
        guard tabs[activeIndex].text != nextText else { return }
        tabs[activeIndex].text = nextText
        clampSelection(for: tabs[activeIndex].id)
        scheduleSave()
    }

    func clear() {
        updateText("")
        updateSelection(for: activeTabID, range: NSRange(location: 0, length: 0))
    }

    func addTab() {
        let tab = NoteTab()
        tabs.append(tab)
        activeTabID = tab.id
        scheduleSave()
    }

    func removeActiveTab() {
        removeTab(activeTabID)
    }

    func removeTab(_ id: UUID) {
        guard tabs.count > 1,
              let removedIndex = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let wasActive = id == activeTabID
        recentlyDeletedNote = DeletedNote(tab: tabs.remove(at: removedIndex), index: removedIndex)
        if wasActive {
            let nextIndex = min(removedIndex, tabs.count - 1)
            activeTabID = tabs[nextIndex].id
        }
        scheduleSave()
    }

    func restoreLastDeletedTab() {
        guard let recentlyDeletedNote else { return }
        let insertionIndex = min(max(recentlyDeletedNote.index, 0), tabs.count)
        tabs.insert(recentlyDeletedNote.tab, at: insertionIndex)
        activeTabID = recentlyDeletedNote.tab.id
        self.recentlyDeletedNote = nil
        scheduleSave()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard activeTabID != id else { return }
        activeTabID = id
        scheduleSave()
    }

    func updateSelection(for id: UUID, range: NSRange) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clamped = clampedRange(range, text: tabs[index].text)
        guard tabs[index].selectionLocation != clamped.location
                || tabs[index].selectionLength != clamped.length else {
            return
        }
        tabs[index].selectionLocation = clamped.location
        tabs[index].selectionLength = clamped.length
        scheduleSave()
    }

    func selectionRange(for id: UUID) -> NSRange {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return NSRange(location: 0, length: 0)
        }

        return clampedRange(
            NSRange(location: tab.selectionLocation ?? 0, length: tab.selectionLength ?? 0),
            text: tab.text
        )
    }

    func title(for id: UUID) -> String {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return "Untitled"
        }

        var title = firstMeaningfulLine(in: tabs[index].text) ?? ""

        while let prefix = ["# ", "## ", "### ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "> "]
            .first(where: { title.hasPrefix($0) }) {
            title.removeFirst(prefix.count)
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Untitled \(index + 1)" }
        return title.count > 42 ? String(title.prefix(41)) + "…" : title
    }

    var canRestoreDeletedNote: Bool {
        recentlyDeletedNote != nil
    }

    func flush(waitForDisk: Bool = true) {
        pendingSave?.cancel()
        pendingSave = nil
        persistNow()
        if waitForDisk {
            persistenceQueue.sync {}
        }
    }

    private var activeIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    private func clampSelection(for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let range = NSRange(location: tabs[index].selectionLocation ?? 0, length: tabs[index].selectionLength ?? 0)
        let clamped = clampedRange(range, text: tabs[index].text)
        tabs[index].selectionLocation = clamped.location
        tabs[index].selectionLength = clamped.length
    }

    private func clampedRange(_ range: NSRange, text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let selectionLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: selectionLength)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.persistNow()
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: save)
    }

    private func persistNow() {
        let savedAt = Date()
        let snapshot = PersistedNotes(tabs: tabs, activeTabID: activeTabID, savedAt: savedAt)

        guard let archiveData = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(archiveData, forKey: Self.archiveDefaultsKey)
        defaults.set(activeTabID.uuidString, forKey: Self.activeTabIDKey)
        defaults.set(text, forKey: Self.legacyTextKey)
        defaults.set(savedAt, forKey: Self.lastSavedAtKey)

        guard let archiveURL else { return }
        persistenceQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: archiveURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try archiveData.write(to: archiveURL, options: .atomic)
            } catch {
                // UserDefaults remains the compatible recovery copy.
            }
        }
    }

    private static func loadLatestSnapshot(
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

    private static func defaultArchiveURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("NotchNotes", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    private func firstMeaningfulLine(in text: String) -> String? {
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                return line
            }

            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }

        return nil
    }
}
