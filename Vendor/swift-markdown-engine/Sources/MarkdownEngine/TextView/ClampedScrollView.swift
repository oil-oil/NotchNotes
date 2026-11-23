//
//  ClampedScrollView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Scroll view that keeps vertical scrolling within a clean top and bottom range.
import AppKit

final class ClampedScrollView: NSScrollView {
    // Keep the compact editor's scrollbar floating even when macOS reapplies
    // the system-wide legacy scroller preference as the view is attached.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

    /// Saved at the start of every live-resize (including spurious one-click resizes triggered by edge-cursor clicks) so the position is restored when the resize ends. Without this, NSScrollView's default top-anchor-during-resize would jolt a bottom-anchored user back up by hundreds of points on a single edge click.
    private var scrollYBeforeLiveResize: CGFloat?
    private var isRefreshingContentHeight = false

    private func refreshContentHeight() {
        guard !isRefreshingContentHeight,
              let textView = documentView as? NativeTextView else { return }
        isRefreshingContentHeight = true
        defer { isRefreshingContentHeight = false }
        // TextKit can finish wrapping after the initial sizing pass. Refresh
        // the cached height before it is used to constrain a scroll offset.
        if let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        textView.recalcOverscroll(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        refreshContentHeight()
        guard event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Apply vertical deltas directly: AppKit's wheel handler can leave the
        // offset unchanged in this panel even after refreshing document geometry.
        // Precise events already contain pixel deltas, including momentum.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : verticalLineScroll
        let delta = event.scrollingDeltaY * scale
        let realHeight = (documentView as? NativeTextView)?.scrollableContentHeight
            ?? documentView?.bounds.height ?? 0
        let minY = -contentInsets.top
        let maxY = max(minY, realHeight - contentView.bounds.height)
        let y = min(max(contentView.bounds.minY - delta, minY), maxY)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: y))
        reflectScrolledClipView(contentView)
        clampToInsets()
        flashScrollers()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        scrollYBeforeLiveResize = contentView.bounds.origin.y
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if let y = scrollYBeforeLiveResize {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
            reflectScrolledClipView(contentView)
            clampToInsets()
        }
        scrollYBeforeLiveResize = nil
    }

    func clampToInsets() {
        refreshContentHeight()
        guard let doc = documentView else { return }
        let minY = -contentInsets.top
        // Use the real content height (not the inflated frame) so small
        // documents can't scroll past their actual content.
        let realHeight = (doc as? NativeTextView)?.scrollableContentHeight ?? doc.bounds.height
        let maxY = max(minY, realHeight - contentView.bounds.height)
        let b = contentView.bounds
        let clampedY = min(max(b.origin.y, minY), maxY)
        if clampedY != b.origin.y {
            contentView.scroll(to: NSPoint(x: b.origin.x, y: clampedY))
            reflectScrolledClipView(contentView)
        }
    }
}
