import AppKit
import XCTest
@testable import NotchNotes

final class FileShelfSelectionTests: XCTestCase {
    private let ids = [UUID(), UUID(), UUID(), UUID()]

    func testCommandClickTogglesIndividualItems() {
        var selection = FileShelfSelection()

        selection.select(ids[0], orderedIDs: ids, modifiers: [])
        selection.select(ids[2], orderedIDs: ids, modifiers: [.command])
        XCTAssertEqual(selection.selectedIDs, Set([ids[0], ids[2]]))

        selection.select(ids[0], orderedIDs: ids, modifiers: [.command])
        XCTAssertEqual(selection.selectedIDs, Set([ids[2]]))
    }

    func testShiftClickAddsAndRemovesContiguousRanges() {
        var selection = FileShelfSelection()

        selection.select(ids[0], orderedIDs: ids, modifiers: [])
        selection.select(ids[2], orderedIDs: ids, modifiers: [.shift])
        XCTAssertEqual(selection.selectedIDs, Set(ids[0...2]))

        selection.select(ids[1], orderedIDs: ids, modifiers: [.shift])
        XCTAssertEqual(selection.selectedIDs, Set([ids[0]]))
    }

    func testSelectAllAndOrderedDragSelection() {
        var selection = FileShelfSelection()

        selection.selectAll(ids)
        XCTAssertEqual(selection.selectedIDs, Set(ids))
        XCTAssertEqual(selection.orderedSelection(from: ids, startingAt: ids[2]), ids)

        selection.selectExclusively(ids[1])
        XCTAssertEqual(
            selection.orderedSelection(from: ids, startingAt: ids[3]),
            [ids[3]]
        )
    }

    func testShiftMarqueeSubtractsAndCommandMarqueeToggles() {
        var selection = FileShelfSelection()
        let initial = Set([ids[0], ids[1], ids[2]])

        selection.applyMarquee(
            enclosedIDs: Set([ids[1], ids[3]]),
            initialSelection: initial,
            modifiers: [.shift]
        )
        XCTAssertEqual(selection.selectedIDs, Set([ids[0], ids[2]]))

        selection.applyMarquee(
            enclosedIDs: Set([ids[1], ids[3]]),
            initialSelection: initial,
            modifiers: [.command]
        )
        XCTAssertEqual(selection.selectedIDs, Set([ids[0], ids[2], ids[3]]))
    }

    func testSelectionDropsIDsThatNoLongerExist() {
        var selection = FileShelfSelection()
        selection.selectAll(ids)

        selection.retainValidIDs(Set(ids[1...2]))

        XCTAssertEqual(selection.selectedIDs, Set(ids[1...2]))
    }
}
