import Foundation
import XCTest
@testable import NotchNotes

@MainActor
final class FileShelfStoreTests: XCTestCase {
    func testShelfDeduplicatesPersistsAndNeverDeletesOriginalFile() throws {
        let suiteName = "FileShelfStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchNotesTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("sample.txt")

        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        try Data("temporary shelf item".utf8).write(to: fileURL)

        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let store = FileShelfStore(defaults: defaults)
        XCTAssertEqual(store.add([fileURL, fileURL]), 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNil(store.items.first?.bookmarkData)

        let restoredStore = FileShelfStore(defaults: defaults)
        let restoredItem = try XCTUnwrap(restoredStore.items.first)
        XCTAssertEqual(restoredStore.resolvedURL(for: restoredItem)?.path, fileURL.path)
        XCTAssertTrue(restoredStore.isAvailable(restoredItem))

        restoredStore.remove(restoredItem)
        XCTAssertTrue(restoredStore.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testShelfAcceptsUnavailablePathsWithoutBlockingDrop() throws {
        let suiteName = "FileShelfStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unavailableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")
        let store = FileShelfStore(defaults: defaults)

        XCTAssertEqual(store.add([unavailableURL]), 1)
        XCTAssertEqual(store.items.first?.fallbackPath, unavailableURL.path)
        XCTAssertNil(store.items.first?.bookmarkData)
    }

    func testShelfRemovesSelectedItemsAsOneOperation() throws {
        let suiteName = "FileShelfStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let urls = ["first.txt", "second.txt", "third.txt"].map {
            FileManager.default.temporaryDirectory.appendingPathComponent($0)
        }
        let store = FileShelfStore(defaults: defaults)
        XCTAssertEqual(store.add(urls), 3)

        store.remove(ids: Set([store.items[0].id, store.items[2].id]))

        XCTAssertEqual(store.items.map(\.originalName), ["second.txt"])
        XCTAssertEqual(FileShelfStore(defaults: defaults).items.map(\.originalName), ["second.txt"])
    }

    func testDropIsHandledWhenFileAlreadyExistsOnShelf() throws {
        let suiteName = "FileShelfStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-\(UUID().uuidString).txt")
        let store = FileShelfStore(defaults: defaults)

        XCTAssertTrue(store.acceptDrop([fileURL]))
        XCTAssertTrue(store.acceptDrop([fileURL]))
        XCTAssertEqual(store.items.count, 1)
    }

    func testShelfIgnoresLegacyTransferMetadata() throws {
        enum LegacyTransferOperation: String, Codable {
            case copy
            case cut
        }

        struct LegacyShelfItem: Codable {
            let id: UUID
            let bookmarkData: Data?
            let fallbackPath: String
            let originalName: String
            let addedAt: Date
            let isDirectory: Bool?
            let fileExtension: String?
            let transferOperation: LegacyTransferOperation?
        }

        let suiteName = "FileShelfStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyItem = LegacyShelfItem(
            id: UUID(),
            bookmarkData: nil,
            fallbackPath: "/tmp/legacy-cut.txt",
            originalName: "legacy-cut.txt",
            addedAt: Date(),
            isDirectory: false,
            fileExtension: "txt",
            transferOperation: .cut
        )
        defaults.set(
            try JSONEncoder().encode([legacyItem]),
            forKey: "notchNotes.fileShelf.v1"
        )

        let store = FileShelfStore(defaults: defaults)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.fallbackPath, legacyItem.fallbackPath)
    }

    func testShelfMigratesItemsSavedBeforeMetadataWasAdded() throws {
        struct LegacyShelfItem: Codable {
            let id: UUID
            let bookmarkData: Data?
            let fallbackPath: String
            let originalName: String
            let addedAt: Date
        }

        let suiteName = "FileShelfStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyItem = LegacyShelfItem(
            id: UUID(),
            bookmarkData: nil,
            fallbackPath: "/tmp/legacy.txt",
            originalName: "legacy.txt",
            addedAt: Date()
        )
        defaults.set(
            try JSONEncoder().encode([legacyItem]),
            forKey: "notchNotes.fileShelf.v1"
        )

        let store = FileShelfStore(defaults: defaults)
        XCTAssertEqual(store.items.first?.id, legacyItem.id)
        XCTAssertNil(store.items.first?.isDirectory)
        XCTAssertNil(store.items.first?.fileExtension)
    }
}
