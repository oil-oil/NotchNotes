import Foundation
import XCTest
@testable import NotchNotes

@MainActor
final class NoteStoreTests: XCTestCase {
    func testPersistsNotesSelectionAndReadableTitles() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanUp() }

        let store = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )
        store.updateText("# Project log\nFirst entry")
        store.updateSelection(
            for: store.activeTabID,
            range: NSRange(location: 4, length: 3)
        )
        XCTAssertEqual(store.title(for: store.activeTabID), "Project log")

        let firstTabID = store.activeTabID
        store.addTab()
        store.updateText("- [ ] Follow up")
        store.flush()

        let restored = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.text, "- [ ] Follow up")
        XCTAssertEqual(restored.title(for: firstTabID), "Project log")
        XCTAssertEqual(
            restored.selectionRange(for: firstTabID),
            NSRange(location: 4, length: 3)
        )
    }

    func testDeletedNoteCanBeRestoredWithoutLosingContent() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanUp() }

        let store = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )
        store.updateText("Keep this note")
        let originalID = store.activeTabID
        store.addTab()

        store.selectTab(originalID)
        store.removeActiveTab()
        XCTAssertTrue(store.canRestoreDeletedNote)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == originalID }))

        store.restoreLastDeletedTab()
        XCTAssertFalse(store.canRestoreDeletedNote)
        XCTAssertEqual(store.activeTabID, originalID)
        XCTAssertEqual(store.text, "Keep this note")
    }

    func testDeletingInactiveNoteKeepsCurrentNoteActive() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanUp() }

        let store = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )
        let firstID = store.activeTabID
        store.addTab()
        let activeID = store.activeTabID

        store.removeTab(firstID)

        XCTAssertEqual(store.activeTabID, activeID)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == firstID }))
        XCTAssertTrue(store.canRestoreDeletedNote)
    }

    func testArchiveRecoversNotesWhenDefaultsDataIsMissing() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanUp() }

        let store = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )
        store.updateText("Recovery copy")
        store.flush()

        environment.defaults.removeObject(forKey: "notchNotes.tabs.v1")
        environment.defaults.removeObject(forKey: "notchNotes.archive.v2")
        environment.defaults.removeObject(forKey: "notchNotes.activeTabID")

        let recovered = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )
        XCTAssertEqual(recovered.text, "Recovery copy")
    }

    func testTitlePrefersFirstATXHeaderAfterBodyAndSkipsCodeBlocks() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanUp() }

        let store = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )

        store.updateText(
            """
            Quick scratchpad note before any heading
            ```python
            # Comment inside backtick code fence
            x = 42
            ```
            ~~~sh
            # Comment inside tilde code fence
            ~~~
            ## **Release** *Plan* `v2` [[Roadmap|550E8400-E29B-41D4-A716-446655440000]] ##
            Body line
            """
        )
        XCTAssertEqual(
            store.title(for: store.activeTabID),
            "Release Plan v2 [[Roadmap]]"
        )

        store.updateText("# Learn C#\nNotes on sharp")
        XCTAssertEqual(store.title(for: store.activeTabID), "Learn C#")

        store.updateText("#hashtag\n#### Deep Section")
        XCTAssertEqual(store.title(for: store.activeTabID), "Deep Section")
    }

    func testTitleFallsBackWhenNoATXHeaderOrWhenHeaderIsEmpty() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanUp() }

        let store = NoteStore(
            defaults: environment.defaults,
            archiveURL: environment.archiveURL
        )

        XCTAssertEqual(store.title(for: store.activeTabID), "Untitled 1")

        store.updateText("#   \n## ###\n")
        XCTAssertEqual(store.title(for: store.activeTabID), "Untitled 1")

        store.updateText("# \n1. Check [[Invoice|12345678-1234-1234-1234-1234567890AB]]")
        XCTAssertEqual(store.title(for: store.activeTabID), "Check [[Invoice]]")

        store.updateText(
            """
            ```
            # Ignored code comment
            ```
            > - [x] Ship universal CLI binary
            """
        )
        XCTAssertEqual(store.title(for: store.activeTabID), "Ship universal CLI binary")

        store.addTab()
        XCTAssertEqual(store.title(for: store.activeTabID), "Untitled 2")

        let longTitle = "# " + String(repeating: "A", count: 50)
        store.updateText(longTitle)
        let truncated = store.title(for: store.activeTabID)
        XCTAssertEqual(truncated.count, 42)
        XCTAssertTrue(truncated.hasSuffix("…"))
    }

    private func makeEnvironment() throws -> TestEnvironment {
        let suiteName = "NoteStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchNotesTests-\(UUID().uuidString)", isDirectory: true)
        return TestEnvironment(
            suiteName: suiteName,
            defaults: defaults,
            directory: directory,
            archiveURL: directory.appendingPathComponent("notes.json")
        )
    }
}

private struct TestEnvironment {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let archiveURL: URL

    func cleanUp() {
        defaults.removeTestSuiteAndPlist(named: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
