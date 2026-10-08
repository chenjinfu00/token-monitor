import AppKit
import SwiftUI

// A floating quota panel has buttons and popovers, but never takes keyboard
// focus away from the application the user is working in.
@MainActor
final class FloatingQuotaPanel: NSPanel {
    var isTrackingCollapsedInteraction = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingWindowGlassView: NSVisualEffectView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    init(frame frameRect: NSRect, cornerRadius: CGFloat) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        // NSVisualEffectView composites its backdrop separately from ordinary
        // CALayer content. Its native alpha mask also shapes the window shadow;
        // a layer cornerRadius alone does not describe that material boundary.
        maskImage = Self.roundedMaterialMask(cornerRadius: cornerRadius)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func roundedMaterialMask(cornerRadius: CGFloat) -> NSImage {
        let radius = cornerRadius.isFinite ? max(0, cornerRadius) : 0
        // A one-point center stretches without scaling the circular corners.
        // The block-backed image renders at the backing scale AppKit requests.
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let mask = NSImage(size: size, flipped: false) { rectangle in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rectangle, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.backgroundColor = .clear
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }

    static func hosting<Content: View>(_ content: Content, frame: NSRect,
                                      cornerRadius: CGFloat = 16) -> FloatingWindowGlassView {
        let glass = FloatingWindowGlassView(frame: frame, cornerRadius: cornerRadius)
        let hosting = FloatingWindowHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        return glass
    }
}

@MainActor
final class FloatingWindowHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    // SwiftUI buttons can share this AppKit hit target. Marking the entire
    // hosting view draggable can turn their clicks into window movement.
    // Dedicated NativeWindowDragRegion views handle title/blank-area drags.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Overlay only a title or dedicated blank area, never a Button/Link or the
// whole widget. This native hit target reliably receives the mouse-down even
// when SwiftUI's hosting view handles other background events itself.
@MainActor
struct NativeWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragHitView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class WindowDragHitView: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// The collapsed summary has no individual buttons. A dedicated native overlay
// owns its pointer sequence, distinguishing clicks from movement before ever
// invoking expand. Main-window buttons and drag regions are unaffected.
@MainActor
struct NativeCollapsedWindowInteraction: NSViewRepresentable {
    let onClick: () -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        CollapsedWindowInteractionView(onClick: onClick, onDragEnded: onDragEnded)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CollapsedWindowInteractionView else { return }
        view.onClick = onClick
        view.onDragEnded = onDragEnded
    }
}

@MainActor
private final class CollapsedWindowInteractionView: NSView {
    var onClick: () -> Void
    var onDragEnded: () -> Void
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    init(onClick: @escaping () -> Void, onDragEnded: @escaping () -> Void) {
        self.onClick = onClick
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        func screenPoint(_ event: NSEvent) -> NSPoint {
            if let cgEvent = event.cgEvent {
                // The incoming event carries a stable screen point, including
                // synthetic events. Never substitute the physical cursor's
                // current position or a point from a later queued event.
                return cgEvent.unflippedLocation
            }
            return event.window == nil ? event.locationInWindow
                : window.convertPoint(toScreen: event.locationInWindow)
        }
        let start = screenPoint(event)
        let origin = window.frame.origin
        let panel = window as? FloatingQuotaPanel
        panel?.isTrackingCollapsedInteraction = true
        var dragged = false
        // performDrag transfers the sequence to WindowServer and may omit a
        // mouse-up callback. Tracking here keeps click and drop unambiguous.
        while window.isVisible {
            let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                until: Date().addingTimeInterval(0.1), inMode: .eventTracking, dequeue: true)
            if let next {
                let current = screenPoint(next)
                let delta = NSPoint(x: current.x - start.x, y: current.y - start.y)
                if !dragged, hypot(delta.x, delta.y) >= 5 { dragged = true }
                if dragged { window.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y)) }
            }
            if next?.type == .leftMouseUp || (next == nil && NSEvent.pressedMouseButtons & 1 == 0) { break }
        }
        panel?.isTrackingCollapsedInteraction = false
        if dragged { onDragEnded() }
        else if window.isVisible { onClick() }
    }
}
