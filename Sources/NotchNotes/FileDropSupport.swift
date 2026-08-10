import AppKit
import Foundation

enum FileDropPayload {
    static func normalizedFileURLs(from urls: [URL]) -> [URL] {
        var knownPaths = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }

            let standardizedURL = url.standardizedFileURL
            guard knownPaths.insert(standardizedURL.path).inserted else {
                return nil
            }
            return standardizedURL
        }
    }
}

@MainActor
enum FileDropPasteboardReader {
    static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) != nil
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.pasteboardItems?.compactMap { item -> URL? in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else {
                return nil
            }
            return url
        } ?? []

        return FileDropPayload.normalizedFileURLs(from: urls)
    }
}

enum FileDragPasteboard {
    static func writer(for url: URL) -> NSURL {
        url.standardizedFileURL as NSURL
    }
}

enum FileDragOperationPolicy {
    static let allowedOperations: NSDragOperation = [.copy, .generic]
}

enum FileDragGesturePolicy {
    static let activationDistance: CGFloat = 8

    static func shouldBegin(from start: NSPoint, to current: NSPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= activationDistance
    }
}
