import SwiftUI
import AppKit

struct NativeScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> IndicatorAnchor { IndicatorAnchor() }
    func updateNSView(_ view: IndicatorAnchor, context: Context) { view.hideIndicators() }
    final class IndicatorAnchor: NSView {
        private var observations: [NSKeyValueObservation] = []
        private var observed = Set<ObjectIdentifier>()
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hideIndicators() }
        func hideIndicators() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { self?.observations = []; self?.observed = []; return }
                var parent = self.superview
                while let view = parent {
                    if let scroll = view as? NSScrollView {
                        if self.observed.insert(ObjectIdentifier(scroll)).inserted {
                            // SwiftUI can restore its native indicators after layout.
                            // Keep those hidden while the viewport owns the visible controls.
                            self.observations += [
                                scroll.observe(\.hasHorizontalScroller, options: [.new]) { view, _ in MainActor.assumeIsolated { if view.hasHorizontalScroller { view.hasHorizontalScroller = false } } },
                                scroll.observe(\.hasVerticalScroller, options: [.new]) { view, _ in MainActor.assumeIsolated { if view.hasVerticalScroller { view.hasVerticalScroller = false } } }
                            ]
                        }
                        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
                    }
                    parent = view.superview
                }
            }
        }
    }
}

/// A viewport-mounted scroller, independent of the system's overlay auto-hide setting.
struct PersistentScroller: NSViewRepresentable {
    var horizontal = false
    var offset: CGFloat
    var contentLength: CGFloat
    var viewportLength: CGFloat
    var onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScroller {
        let scroller = NSScroller(frame: horizontal ? NSRect(x: 0, y: 0, width: 300, height: 16) : NSRect(x: 0, y: 0, width: 16, height: 300))
        scroller.scrollerStyle = .legacy
        scroller.target = context.coordinator
        scroller.action = #selector(Coordinator.changed(_:))
        scroller.setAccessibilityLabel(horizontal ? "横向滚动路线" : "纵向滚动路线")
        return scroller
    }
    func updateNSView(_ scroller: NSScroller, context: Context) {
        context.coordinator.owner = self
        scroller.knobProportion = min(1, viewportLength / max(1, contentLength))
        scroller.doubleValue = Double(min(1, max(0, offset / max(1, contentLength - viewportLength))))
        scroller.isEnabled = contentLength > viewportLength
    }
    @MainActor final class Coordinator: NSObject {
        var owner: PersistentScroller
        init(_ owner: PersistentScroller) { self.owner = owner }
        @objc func changed(_ sender: NSScroller) {
            let limit = max(0, owner.contentLength - owner.viewportLength)
            let target: CGFloat
            switch sender.hitPart {
            case .decrementPage: target = owner.offset - owner.viewportLength * 0.85
            case .incrementPage: target = owner.offset + owner.viewportLength * 0.85
            case .decrementLine: target = owner.offset - 40
            case .incrementLine: target = owner.offset + 40
            default: target = CGFloat(sender.doubleValue) * limit
            }
            owner.onScroll(min(limit, max(0, target)))
        }
    }
}
