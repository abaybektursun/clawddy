import AppKit

/// Borderless floating Spotlight-style panel. On macOS 26 the content is
/// wrapped in an NSGlassEffectView so the panel reads as a single floating
/// Liquid Glass surface (the glass lenses the wallpaper and draws its own
/// ambient shadow — no stroke, no manual shadow). The hosted SwiftUI palette
/// draws no background of its own; this glass is the surface.
final class AgentSearchPanel: NSPanel {

    /// The hosted SwiftUI content (NSHostingView). Kept to size the panel to
    /// its fitting size so the panel grows/shrinks with the result count.
    private let hostedView: NSView
    private var fallbackEffectView: NSVisualEffectView?
    private var animationGeneration = 0
    private var previousApplication: NSRunningApplication?
    private var selectionCommitted = false

    /// Outer corner radius of the glass surface. The hosted content's own
    /// corners stay square; the glass masks them to this radius.
    private let cornerRadius: CGFloat = 26

    init(contentView: NSView) {
        self.hostedView = contentView
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        // The glass surface defines a rounded, translucent shape, so the
        // window shadow follows that shape — a soft ambient Spotlight shadow,
        // not a hard rectangle.
        hasShadow = true
        isMovableByWindowBackground = false

#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // Without clipsToBounds the glass renders rounded but its view
            // bounds stay square, so the window paints/shadows the full
            // rectangle behind it — the hard black outline. Clip to the
            // rounded shape so the window shadow follows the glass.
            glass.clipsToBounds = true
            glass.contentView = contentView
            self.contentView = glass
        } else {
            installFallbackSurface(contentView)
        }
#else
        installFallbackSurface(contentView)
#endif
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        hide(restorePreviousApplication: false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            hide(restorePreviousApplication: true)
        } else {
            super.keyDown(with: event)
        }
    }

    func showCentered() {
        animationGeneration += 1
        if !isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                ? nil
                : frontmost
            selectionCommitted = false
        }
        updateFallbackSurface()
        let pointer = NSEvent.mouseLocation
        guard let screen = NSApp.keyWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
        else { return }

        // Size the panel to the content's fitting height so it hugs the
        // results (Spotlight grows/shrinks with matches).
        let fitting = hostedView.fittingSize
        let width: CGFloat = 540
        let height = max(120, min(fitting.height, screen.visibleFrame.height - 120))
        setContentSize(NSSize(width: width, height: height))

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        // Spotlight-style upper-third placement, clamped so the top never
        // overflows the visible screen (matters on small laptop displays).
        let preferredY = screenFrame.midY + screenFrame.height * 0.15
        let maxY = screenFrame.maxY - frame.height - 20
        let y = min(preferredY, maxY)
        setFrameOrigin(NSPoint(x: x, y: y))

        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSApp.activate(ignoringOtherApps: true)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }
    }

    func commitSelection() {
        selectionCommitted = true
    }

    func hide(restorePreviousApplication: Bool = true) {
        guard isVisible else { return }
        animationGeneration += 1
        let generation = animationGeneration
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            orderOut(nil)
            finishDismissal(restorePreviousApplication: restorePreviousApplication)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            guard generation == self.animationGeneration else { return }
            self.orderOut(nil)
            self.finishDismissal(restorePreviousApplication: restorePreviousApplication)
        })
    }

    private func finishDismissal(restorePreviousApplication: Bool) {
        let clawddyIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        if restorePreviousApplication, clawddyIsFrontmost, !selectionCommitted,
           let previousApplication, !previousApplication.isTerminated {
            _ = previousApplication.activate(options: [])
        }
        previousApplication = nil
        selectionCommitted = false
    }

    private func installFallbackSurface(_ contentView: NSView) {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: effect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        fallbackEffectView = effect
        self.contentView = effect
    }

    private func updateFallbackSurface() {
        guard let effect = fallbackEffectView else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            effect.material = .contentBackground
            effect.blendingMode = .withinWindow
        } else {
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
        }
    }
}
