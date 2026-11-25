import AppKit
import QuartzCore

/// Pictures of a window drawn inside the process, never read from the
/// screen, so they need no Screen Recording permission and come out the same
/// with the window transparent, behind every other window, on a locked
/// screen or a sleeping display.
///
/// The picture is the window's layer tree drawn with `CALayer.render(in:)`.
/// Ghostty presents each terminal frame by setting its layer's contents to
/// an IOSurface (IOSurfaceLayer.zig), and `render(in:)` draws that surface,
/// in its own colour space (Display P3), in its place in the tree, under
/// what lies over it (`AgentWindowCaptureTests`): no copy of the surface is
/// needed.
@MainActor
enum AgentWindowCapture {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The whole window, title bar band included, at its backing scale, in
    /// sRGB. With `presentation`, layers as they are shown at this moment of
    /// their animations rather than as they will end.
    static func picture(of window: NSWindow, presentation: Bool = false) throws -> NSBitmapImageRep {
        let root = try rootLayer(of: window)
        guard let frameView = window.contentView?.superview else {
            throw Failure(reason: "The window has no frame view.")
        }
        window.layoutIfNeeded()
        frameView.displayIfNeeded()
        let scale = window.backingScaleFactor
        let bounds = frameView.bounds
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int((bounds.width * scale).rounded()),
                height: Int((bounds.height * scale).rounded()),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(reason: "No bitmap context for \(bounds.size) at scale \(scale).") }
        context.scaleBy(x: scale, y: scale)

        let restoreDecorations = hideWindowServerDecorations(in: frameView, of: window)
        defer { restoreDecorations() }
        if presentation {
            // The decorations hidden above reach the presentation tree only
            // when committed.
            CATransaction.flush()
        }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let layer = presentation ? (root.presentation() ?? root) : root
        layer.render(in: context)

        guard let image = context.makeImage() else { throw Failure(reason: "The bitmap made no image.") }
        let picture = NSBitmapImageRep(cgImage: image)
        picture.size = bounds.size
        return picture
    }

    /// Pictures of a transition: stops the window's animation clock,
    /// performs `action`, then draws the window each `step` seconds of
    /// animation time up to `duration`, as its Core Animation animations show
    /// it then, those already running included. Deterministic, so it shows
    /// the motion's shape; how smoothly it plays on glass is another matter.
    /// AppKit's own animations, such as a split view item collapsing, are
    /// not Core Animation's: they are not stepped, and while the screen is
    /// locked they do not run at all.
    static func frames(
        of window: NSWindow,
        duration: TimeInterval,
        step: TimeInterval,
        then later: [(at: TimeInterval, action: () async throws -> Void)] = [],
        action: () async throws -> Void
    ) async throws -> [NSBitmapImageRep] {
        let root = try rootLayer(of: window)
        guard step > 0, duration >= 0 else { throw Failure(reason: "frames needs a positive step.") }
        let (speed, offset) = (root.speed, root.timeOffset)
        // Held at this moment: animations running now stay where they are,
        // and those the action adds begin here.
        let start = root.convertTime(CACurrentMediaTime(), from: nil)
        root.speed = 0
        root.timeOffset = start
        defer {
            // The clock runs on from now, past the end of what the action added.
            root.speed = speed
            root.timeOffset = offset
        }
        try await action()
        var pictures: [NSBitmapImageRep] = []
        var pending = later
        // A little over, so 1.2 / 0.2 is 6 steps, not 5.999.
        for index in 0...Int((duration / step + 1e-6).rounded(.down)) {
            let time = Double(index) * step
            // Another key at its moment of animation time.
            while let next = pending.first, next.at <= time + 1e-6 {
                pending.removeFirst()
                root.timeOffset = start + next.at
                try await next.action()
            }
            root.timeOffset = start + time
            pictures.append(try picture(of: window, presentation: true))
        }
        return pictures
    }

    /// Values of a transition at exact moments of animation time: as
    /// `frames`, but reading `value` at each step instead of drawing.
    static func values(
        of window: NSWindow,
        duration: TimeInterval,
        step: TimeInterval,
        action: () async throws -> Void,
        value: (CALayer) -> Double?
    ) async throws -> [[Double]] {
        let root = try rootLayer(of: window)
        let (speed, offset) = (root.speed, root.timeOffset)
        let start = root.convertTime(CACurrentMediaTime(), from: nil)
        root.speed = 0
        root.timeOffset = start
        defer {
            root.speed = speed
            root.timeOffset = offset
        }
        try await action()
        var values: [[Double]] = []
        for index in 0...Int((duration / step + 1e-6).rounded(.down)) {
            root.timeOffset = start + Double(index) * step
            CATransaction.flush()
            if let found = value(root) { values.append([Double(index) * step, found]) }
        }
        return values
    }

    /// The layer of the window's frame view, the root of everything the
    /// window draws, made layer-backed if it is not yet.
    private static func rootLayer(of window: NSWindow) throws -> CALayer {
        guard let frameView = window.contentView?.superview else {
            throw Failure(reason: "The window has no frame view.")
        }
        if frameView.layer == nil {
            frameView.wantsLayer = true
            frameView.layoutSubtreeIfNeeded()
            frameView.displayIfNeeded()
        }
        guard let root = frameView.layer else { throw Failure(reason: "The window has no layer tree to draw.") }
        return root
    }

    /// The pictures side by side at a quarter of their size, to judge a
    /// strip at a glance.
    static func strip(_ pictures: [NSBitmapImageRep]) throws -> NSBitmapImageRep {
        guard let first = pictures.first, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure(reason: "No pictures to put in a strip.")
        }
        let width = first.pixelsWide / 4
        let height = first.pixelsHigh / 4
        let gap = 8
        guard let context = CGContext(
            data: nil,
            width: pictures.count * (width + gap) - gap,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(reason: "No bitmap context for the strip.") }
        context.interpolationQuality = .high
        for (index, picture) in pictures.enumerated() {
            guard let image = picture.cgImage else { continue }
            context.draw(image, in: CGRect(x: index * (width + gap), y: 0, width: width, height: height))
        }
        guard let image = context.makeImage() else { throw Failure(reason: "The strip made no image.") }
        return NSBitmapImageRep(cgImage: image)
    }

    /// Where each terminal of the window is in its pictures: pixels from
    /// the top left, [x, y, width, height], at the window's backing scale.
    static func terminalRects(in window: NSWindow) -> [[Double]] {
        guard let frameView = window.contentView?.superview else { return [] }
        let scale = window.backingScaleFactor
        return frameView.descendants(of: Ghostty.SurfaceView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map { surface in
                let rect = surface.convert(surface.bounds, to: frameView)
                let top = frameView.isFlipped ? rect.minY : frameView.bounds.height - rect.maxY
                return [rect.minX, top, rect.width, rect.height].map { Double($0 * scale) }
            }
    }

    // MARK: - Window server decorations

    /// `CALayer.render(in:)` draws the layer tree the app built, but not
    /// what only the window server composites: backdrop blur, glass and
    /// vibrancy. On macOS 26 every `NSScrollView` holds a scroll edge effect
    /// made of such layers, and its presence leaves the whole scroll view
    /// undrawn; glass draws as an opaque white panel. So, for the picture
    /// only, this hides those decorations and puts a flat panel where each
    /// glass shape is, and returns what puts them back. Vibrancy has no
    /// public way out: what the sidebar list draws vibrant keeps the colours
    /// it has before the window server's filter.
    private static func hideWindowServerDecorations(in frameView: NSView, of window: NSWindow) -> () -> Void {
        struct Style {
            let layer: CALayer
            let background: CGColor?
            let border: CGColor?
            let width: CGFloat
            let radius: CGFloat
        }
        var hidden: [NSView] = []
        var styled: [Style] = []
        func hide(_ view: NSView) {
            guard !view.isHidden else { return }
            view.isHidden = true
            hidden.append(view)
        }
        func hide(_ view: NSView, keeping content: NSView?) {
            for sub in view.subviews where content.map({ !$0.isDescendant(of: sub) }) ?? true {
                hide(sub)
            }
        }
        for scroll in frameView.descendants(of: NSScrollView.self) {
            for sub in scroll.subviews where sub !== scroll.contentView && !(sub is NSScroller) {
                hide(sub)
            }
        }
        if #available(macOS 26.0, *) {
            var panel: CGColor?
            var outline: CGColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                panel = NSColor.windowBackgroundColor.blended(withFraction: 0.06, of: .labelColor)?.cgColor
                outline = NSColor.separatorColor.cgColor
            }
            for glass in frameView.descendants(of: NSGlassEffectView.self) {
                hide(glass, keeping: glass.contentView)
                if let layer = glass.layer {
                    styled.append(Style(
                        layer: layer, background: layer.backgroundColor, border: layer.borderColor,
                        width: layer.borderWidth, radius: layer.cornerRadius))
                    layer.backgroundColor = panel
                    layer.borderColor = outline
                    layer.borderWidth = 1
                    layer.cornerRadius = min(glass.bounds.height / 2, 18)
                }
            }
            for container in frameView.descendants(of: NSGlassEffectContainerView.self) {
                hide(container, keeping: container.contentView)
            }
        }
        if let split = window.contentViewController as? NSSplitViewController {
            for item in split.splitViewItems {
                let content = item.viewController.view
                if let wrapper = split.splitView.arrangedSubviews.first(where: content.isDescendant(of:)) {
                    hide(wrapper, keeping: content)
                }
            }
        }
        return {
            for view in hidden { view.isHidden = false }
            for style in styled {
                style.layer.backgroundColor = style.background
                style.layer.borderColor = style.border
                style.layer.borderWidth = style.width
                style.layer.cornerRadius = style.radius
            }
        }
    }
}

extension NSView {
    /// Every view under this one of `type`, depth first.
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { [$0 as? T].compactMap { $0 } + $0.descendants(of: type) }
    }
}

extension NSBitmapImageRep {
    /// The picture as PNG, in the colour space it was drawn in.
    func pngData() throws -> Data {
        guard let data = representation(using: .png, properties: [:]) else {
            throw AgentWindowCapture.Failure(reason: "The picture could not be encoded as PNG.")
        }
        return data
    }
}
