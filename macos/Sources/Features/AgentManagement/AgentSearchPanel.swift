import AppKit

/// Borderless floating Spotlight-style panel hosting Ghostty's own command
/// palette, which draws its own material card, border, and shape. The panel
/// supplies only positioning, key handling, and app-restoration behavior.
final class AgentSearchPanel: NSPanel {

    /// The hosted SwiftUI content (NSHostingView). Kept to size the panel to
    /// its fitting size so the panel grows/shrinks with the result count.
    private let hostedView: NSView
    private var animationGeneration = 0
    private var previousApplication: NSRunningApplication?
    private var selectionCommitted = false

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
        // The palette's rounded card defines the opaque shape, so the window
        // shadow follows it rather than a hard rectangle.
        hasShadow = true
        isMovableByWindowBackground = false
        self.contentView = contentView
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
}
