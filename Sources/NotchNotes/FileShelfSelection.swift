import AppKit
import Foundation

struct FileShelfSelection: Equatable {
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var anchorID: UUID?

    var isEmpty: Bool {
        selectedIDs.isEmpty
    }

    mutating func select(
        _ id: UUID,
        orderedIDs: [UUID],
        modifiers: NSEvent.ModifierFlags
    ) {
        let selectionModifiers = modifiers.intersection([.command, .shift])

        if selectionModifiers.contains(.shift) {
            let rangeIDs = selectionRange(to: id, orderedIDs: orderedIDs)
            if selectedIDs.contains(id) {
                selectedIDs.subtract(rangeIDs)
            } else {
                selectedIDs.formUnion(rangeIDs)
            }
            anchorID = id
            return
        }

        if selectionModifiers.contains(.command) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
            anchorID = id
            return
        }

        selectExclusively(id)
    }

    mutating func selectForMouseDown(
        _ id: UUID,
        orderedIDs: [UUID],
        modifiers: NSEvent.ModifierFlags
    ) {
        let selectionModifiers = modifiers.intersection([.command, .shift])
        if selectionModifiers.isEmpty, selectedIDs.contains(id) {
            anchorID = id
            return
        }

        select(id, orderedIDs: orderedIDs, modifiers: modifiers)
    }

    mutating func selectExclusively(_ id: UUID) {
        selectedIDs = [id]
        anchorID = id
    }

    mutating func selectAll(_ orderedIDs: [UUID]) {
        selectedIDs = Set(orderedIDs)
        anchorID = orderedIDs.first
    }

    mutating func applyMarquee(
        enclosedIDs: Set<UUID>,
        initialSelection: Set<UUID>,
        modifiers: NSEvent.ModifierFlags
    ) {
        if modifiers.contains(.shift) {
            selectedIDs = initialSelection.subtracting(enclosedIDs)
        } else if modifiers.contains(.command) {
            selectedIDs = initialSelection.symmetricDifference(enclosedIDs)
        } else {
            selectedIDs = enclosedIDs
        }
    }

    mutating func retainValidIDs(_ validIDs: Set<UUID>) {
        selectedIDs.formIntersection(validIDs)
        if let anchorID, !validIDs.contains(anchorID) {
            self.anchorID = selectedIDs.first
        }
    }

    mutating func clear() {
        selectedIDs = []
        anchorID = nil
    }

    func orderedSelection(from orderedIDs: [UUID], startingAt id: UUID? = nil) -> [UUID] {
        let ids: Set<UUID>
        if let id, !selectedIDs.contains(id) {
            ids = [id]
        } else {
            ids = selectedIDs
        }
        return orderedIDs.filter(ids.contains)
    }

    private func selectionRange(to id: UUID, orderedIDs: [UUID]) -> Set<UUID> {
        guard let anchorID,
              let anchorIndex = orderedIDs.firstIndex(of: anchorID),
              let targetIndex = orderedIDs.firstIndex(of: id) else {
            return [id]
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        return Set(orderedIDs[lowerBound...upperBound])
    }
}
