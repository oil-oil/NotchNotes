import Combine
import Foundation
@_exported import NotchNotesCore

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var tabs: [NoteTab]
    @Published private(set) var activeTabID: UUID

    private static let saveDelay: TimeInterval = 0.18

    private struct DeletedNote {
        let tab: NoteTab
        let index: Int
    }

    private let defaults: UserDefaults
    private let archiveURL: URL?
    private let persistenceQueue = DispatchQueue(label: "io.github.oiloil.NotchNotes.persistence")
    private var pendingSave: DispatchWorkItem?
    private var isDirty = false
    private var recentlyDeletedNote: DeletedNote?

    init(
        defaults: UserDefaults = NoteStore.defaultUserDefaults(),
        archiveURL: URL? = NoteStore.defaultArchiveURL()
    ) {
        self.defaults = defaults
        self.archiveURL = archiveURL

        let initialState = Self.loadStateSynchronized(defaults: defaults, archiveURL: archiveURL)
        tabs = initialState.tabs
        activeTabID = initialState.activeTabID

        if archiveURL == nil || !FileManager.default.fileExists(atPath: archiveURL!.path) {
            persistNow()
        }
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

    @discardableResult
    func updateText(_ nextText: String, for id: UUID) -> NoteTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        if tabs[index].text != nextText {
            tabs[index].text = nextText
            clampSelection(for: id)
            scheduleSave()
        }
        return tabs[index]
    }

    @discardableResult
    func appendText(_ appendedText: String, to id: UUID, insertNewlineIfNeeded: Bool = true) -> NoteTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let current = tabs[index].text
        let needsNewline = insertNewlineIfNeeded && !current.isEmpty && !current.hasSuffix("\n")
        let nextText = needsNewline ? current + "\n" + appendedText : current + appendedText
        return updateText(nextText, for: id)
    }

    func clear() {
        updateText("")
        updateSelection(for: activeTabID, range: NSRange(location: 0, length: 0))
    }

    func addTab() {
        _ = addTab(text: "", select: true)
    }

    @discardableResult
    func addTab(text: String, select: Bool) -> NoteTab {
        let tab = NoteTab(text: text)
        tabs.append(tab)
        if select {
            activeTabID = tab.id
        }
        scheduleSave()
        return tab
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

    func title(for id: UUID, language: AppLanguage = .english) -> String {
        let untitled = AppStrings(language: language).untitledNote
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return untitled
        }

        return NoteTitleExtractor.title(
            for: tabs[index].text,
            index: index,
            untitledPrefix: untitled
        )
    }

    var canRestoreDeletedNote: Bool {
        recentlyDeletedNote != nil
    }

    func flush(waitForDisk: Bool = true) {
        pendingSave?.cancel()
        pendingSave = nil
        if isDirty {
            persistNow()
        }
        if waitForDisk {
            persistenceQueue.sync {}
        }
    }

    func flushAsync() async {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty else {
            await withCheckedContinuation { continuation in
                persistenceQueue.async {
                    continuation.resume()
                }
            }
            return
        }

        let savedAt = Date()
        let snapshot = PersistedNotes(tabs: tabs, activeTabID: activeTabID, savedAt: savedAt)
        isDirty = false

        guard let archiveData = try? JSONEncoder().encode(snapshot) else { return }
        NoteStorage.writeDefaultsSnapshot(snapshot, archiveData: archiveData, defaults: defaults)

        guard let archiveURL else { return }
        await withCheckedContinuation { continuation in
            persistenceQueue.async {
                do {
                    try NoteStorage.writeArchiveFileLocked(archiveData, to: archiveURL)
                } catch {
                    // UserDefaults remains the compatible recovery copy.
                }
                continuation.resume()
            }
        }
    }

    func reloadFromDiskIfClean() {
        guard !isDirty, pendingSave == nil else { return }
        let latest = Self.loadStateSynchronized(defaults: defaults, archiveURL: archiveURL)
        if tabs != latest.tabs {
            tabs = latest.tabs
        }
        if activeTabID != latest.activeTabID {
            activeTabID = latest.activeTabID
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
        let clamped = NoteStorage.clampedSelection(
            location: range.location,
            length: range.length,
            for: text
        )
        return NSRange(location: clamped.0, length: clamped.1)
    }

    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.persistNow()
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: save)
    }

    private func persistNow() {
        isDirty = false
        let savedAt = Date()
        let snapshot = PersistedNotes(tabs: tabs, activeTabID: activeTabID, savedAt: savedAt)

        guard let archiveData = try? JSONEncoder().encode(snapshot) else { return }
        NoteStorage.writeDefaultsSnapshot(snapshot, archiveData: archiveData, defaults: defaults)

        guard let archiveURL else { return }
        persistenceQueue.async {
            do {
                try NoteStorage.writeArchiveFileLocked(archiveData, to: archiveURL)
            } catch {
                // UserDefaults remains the compatible recovery copy.
            }
        }
    }

    private static func loadStateSynchronized(
        defaults: UserDefaults,
        archiveURL: URL?
    ) -> (tabs: [NoteTab], activeTabID: UUID) {
        guard let archiveURL else {
            return NoteStorage.loadInitialState(defaults: defaults, archiveURL: nil)
        }
        return (try? NoteStorage.withExclusiveFileLock(for: archiveURL) {
            NoteStorage.loadInitialState(defaults: defaults, archiveURL: archiveURL)
        }) ?? NoteStorage.loadInitialState(defaults: defaults, archiveURL: archiveURL)
    }

    static func defaultUserDefaults() -> UserDefaults {
        NoteStorage.resolveUserDefaults()
    }

    static func defaultArchiveURL() -> URL? {
        NoteStorage.defaultArchiveURL()
    }
}
