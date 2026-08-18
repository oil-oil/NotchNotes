import AppKit
import CoreGraphics

struct NotchLayout: Equatable {
    let notchSize: NSSize
    let compactSize: NSSize
    let expandedSize: NSSize
    let compactTopOffset: CGFloat
    let expandedTopOffset: CGFloat
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }

    var isBuiltInDisplay: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    var measuredNotchSize: NSSize {
        guard #available(macOS 12.0, *), safeAreaInsets.top > 0 else {
            return .zero
        }

        guard let leftArea = auxiliaryTopLeftArea, let rightArea = auxiliaryTopRightArea else {
            return .zero
        }

        let notchWidth = frame.width - leftArea.width - rightArea.width
        guard notchWidth > 0, notchWidth < frame.width else {
            return .zero
        }

        return NSSize(width: notchWidth, height: safeAreaInsets.top)
    }
}

@MainActor
enum NotchGeometry {
    static let fileDropTargetExtension: CGFloat = 28

    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: \.isBuiltInDisplay)
            ?? NSScreen.screens.first { $0.measuredNotchSize != .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func layout(for screen: NSScreen?) -> NotchLayout {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let measured = screen?.measuredNotchSize ?? .zero
        let fallbackNotch = NSSize(width: 210, height: 32)
        let notch = measured == .zero ? fallbackNotch : measured

        let compactWidth = min(max(notch.width - 6, 182), 238)
        let compactHeight = min(max(notch.height + 2, 32), 38)
        let expandedWidth = min(max(notch.width + 220, 480), 540, screenFrame.width - 36)
        let expandedHeight = min(max(notch.height + 374, 408), screenFrame.height - 84)

        return NotchLayout(
            notchSize: notch,
            compactSize: NSSize(width: compactWidth, height: compactHeight),
            expandedSize: NSSize(width: expandedWidth, height: expandedHeight),
            compactTopOffset: 0,
            expandedTopOffset: 0
        )
    }

    static func activationFrame(for layout: NotchLayout, in screenFrame: NSRect) -> NSRect {
        let activationSize = NSSize(
            width: layout.notchSize.width,
            height: layout.compactSize.height
        )
        return topCenteredFrame(
            for: activationSize,
            topY: screenFrame.maxY + layout.compactTopOffset,
            in: screenFrame
        )
    }

    static func fileDropFrame(for layout: NotchLayout, in screenFrame: NSRect) -> NSRect {
        var frame = activationFrame(for: layout, in: screenFrame)
        frame.origin.y -= fileDropTargetExtension
        frame.size.height += fileDropTargetExtension
        return frame
    }

    static func topCenteredFrame(
        for size: NSSize,
        topY: CGFloat,
        in screenFrame: NSRect
    ) -> NSRect {
        NSRect(
            x: screenFrame.midX - size.width / 2,
            y: topY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
