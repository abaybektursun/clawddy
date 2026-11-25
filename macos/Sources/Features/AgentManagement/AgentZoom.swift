import AppKit
import QuartzCore

/// How a change between home and inside moves.
@MainActor
enum AgentRegionMotion {
    case none
    /// Entering or leaving `agent`, whose tile is `tile` when home shows
    /// it; `settling` leaves by settling it. `done` runs once the views
    /// rest (leaving: the terminal is hidden then, not before).
    case zoom(agent: UUID, tile: AgentTileView?, settling: Bool, done: () -> Void)
}

/// The view the tile's snapshot moves in, just over the screen, so its
/// layer's order among the window's regions is AppKit's to keep.
final class AgentZoomCover: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { AgentLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The enter or leave motion under way.
@MainActor
struct AgentZoomState {
    enum Kind { case grow, fade }
    var agent: UUID?
    var kind: Kind = .fade
    var inward = true
    var tile: CGRect = .zero
    var full: CGRect = .zero
    var scale: CGFloat = 1
    var snapshot: CALayer?
    weak var tileView: AgentTileView?
    /// The motion leaves by settling the agent into its settled place.
    var settling = false
    /// Each start bumps it; an end scheduled by an older start does nothing.
    var generation = 0
    /// What runs once the views rest (leaving: hides the terminal), however
    /// the motion ends: on its own, or stopped by another change.
    var done: (() -> Void)?
}

/// Entering and leaving a terminal (flows.md 7, ruling 21). Entering, the
/// terminal grows from the tile's outer rectangle to its full rectangle in
/// 160 ms on the one curve, inside the screen's square clipping (the
/// screen's own layer: its position and size move, its content scales by
/// `sublayerTransform`; the terminal's views never change size). The tile's
/// content leaves it from the first frame and, over the screen, fades out over
/// the first 50 ms, covering any stale terminal frame; the list and header
/// fade in after 50 ms; home and the line are gone by half-way. Leaving is
/// the reverse. With no tile on screen, or under Reduce Motion, the views
/// cross-fade; while the window cannot be seen, nothing moves. A motion
/// reversed or retargeted mid-way runs from what is on screen; a motion
/// for another agent starts clean.
extension AgentWindowView {
    /// Which kind a motion is, and for how long (flows.md 7): a grow with
    /// a tile in view, a cross-fade without one or under Reduce Motion, at
    /// once (nil) while the window cannot be seen.
    static func zoomKind(tileInView: Bool, reduced: Bool, visible: Bool) -> (kind: AgentZoomState.Kind, duration: CFTimeInterval)? {
        guard visible else { return nil }
        if tileInView && !reduced { return (.grow, AgentMotion.zoom) }
        return (.fade, AgentMotion.duration(.fade(AgentMotion.small), reduced: reduced, visible: true))
    }

    func zoom(inward: Bool, agent: UUID, tile: AgentTileView?, settling: Bool, done: @escaping () -> Void) {
        let tileRect = tile.map { convert($0.bounds, from: $0) }
        // In view: its centre within what home shows, above the bottom
        // 16 pt (the prototype's rule).
        let inView = tileRect.map { home.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) && $0.midY < home.frame.maxY - 16 } ?? false
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard let (kind, duration) = Self.zoomKind(tileInView: inView, reduced: AgentMotion.reduced, visible: visible) else {
            stopZoom()
            setRegions(inside: inward)
            done()
            return
        }
        let reuse = zoomState.agent == agent && zoomState.kind == .grow && kind == .grow && !settling
        if zoomState.agent != nil, !reuse { stopZoom() }
        zoomState.generation += 1
        let generation = zoomState.generation
        zoomState.agent = agent
        zoomState.kind = kind
        zoomState.inward = inward
        zoomState.settling = settling
        zoomState.done = done
        // The regions that arrive are at opacity 0 for their first 50 ms:
        // they join the window after the key's frame is committed, so that
        // frame lays out and draws only what it shows (they take no pointer
        // meanwhile; the state changed at the key). A newer motion decides
        // for itself.
        AgentMotion.afterThisFrame { [weak self] in
            guard let self, self.zoomState.generation == generation, self.isInside == inward else { return }
            for view in inward ? [self.list, self.header] : [self.home, self.line] as [NSView] where self.hasProjects {
                view.isHidden = false
            }
            self.showHomeParts()
        }
        AgentMotion.run({
            let arrive = [list.layer, header.layer].compactMap { $0 }
            // Home's edge pills go and come with home.
            let depart = ([home, line] + homeParts).compactMap(\.layer)
            switch kind {
            case .fade:
                // Two views never sit on top of each other: the leaving one is
                // gone by half-way, the arriving one starts at a quarter.
                let incoming = inward ? arrive + [screen.layer].compactMap { $0 } : depart
                let outgoing = inward ? depart : arrive + [screen.layer].compactMap { $0 }
                for layer in incoming {
                    AgentMotion.animate(layer, "opacity", to: Float(1), duration: duration, from: Float(0), hold: [(0.25, Float(0))])
                }
                for layer in outgoing {
                    AgentMotion.animate(layer, "opacity", to: Float(0), duration: duration, from: Float(1), hold: [(0.5, Float(0))])
                }
            case .grow:
                grow(inward: inward, tile: tile!, tileRect: tileRect!, reuse: reuse, settling: settling)
                // The list and header: in after 50 ms, or out over the first 50.
                for layer in arrive {
                    AgentMotion.animate(
                        layer, "opacity", to: Float(inward ? 1 : 0), duration: duration, from: Float(inward ? 0 : 1),
                        hold: [(AgentMotion.snapFade / duration, Float(0))])
                }
                // Home and the line: gone by half-way, or in after 50 ms (from
                // a sixth of the way when settling, as the terminal goes, so
                // no frame between is bare canvas).
                let comeBack = settling ? 0.15 : AgentMotion.snapFade / duration
                for layer in depart {
                    AgentMotion.animate(
                        layer, "opacity", to: Float(inward ? 0 : 1), duration: duration, from: Float(inward ? 1 : 0),
                        hold: inward ? [(0.5, Float(0))] : [(comeBack, Float(0))])
                }
            }
        }, then: { [weak self] in
            guard let self, self.zoomState.generation == generation else { return }
            self.endZoom()
        })
    }

    /// The terminal's screen grows from the tile (or shrinks into it).
    private func grow(inward: Bool, tile: AgentTileView, tileRect: CGRect, reuse: Bool, settling: Bool) {
        guard let layer = screen.layer else { return }
        let full = screen.frame
        let scale = reuse ? zoomState.scale : max(tileRect.width / full.width, tileRect.height / full.height)
        let tileRect = reuse ? zoomState.tile : tileRect
        zoomState.full = full
        zoomState.tile = tileRect
        zoomState.scale = scale
        zoomState.tileView = tile
        let duration = AgentMotion.zoom
        let small = (origin: tileRect.origin, size: tileRect.size, transform: CATransform3DMakeScale(scale, scale, 1), radius: CGFloat(12))
        let big = (origin: full.origin, size: full.size, transform: CATransform3DIdentity, radius: CGFloat(10))
        let (from, to) = inward ? (small, big) : (big, small)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = true
        layer.removeAnimation(forKey: "opacity")
        layer.opacity = 1
        CATransaction.commit()
        AgentMotion.animate(layer, "position", to: NSValue(point: to.origin), duration: duration, from: NSValue(point: from.origin))
        AgentMotion.animate(
            layer, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: to.size)), duration: duration,
            from: NSValue(rect: CGRect(origin: .zero, size: from.size)))
        AgentMotion.animate(layer, "sublayerTransform", to: to.transform, duration: duration, from: from.transform)
        AgentMotion.animate(layer, "cornerRadius", to: to.radius, duration: duration, from: from.radius)
        if settling {
            tile.isZoomed = true
            // Settling inside: the terminal is gone by half-way, and the
            // settled place shows over the second half, so no terminal text
            // shows through "Settled <name>" (ruling 22).
            AgentMotion.animate(layer, "opacity", to: Float(0), duration: duration, hold: [(0.5, Float(0))])
            if let place = tile.settledPlace?.layer {
                place.removeAnimation(forKey: "opacity")
                place.opacity = 0
                AgentMotion.animate(place, "opacity", to: Float(1), duration: duration, hold: [(0.5, Float(0))])
            }
            return
        }
        // The tile's snapshot over the growing screen, stretched with it.
        let snapshot: CALayer
        if reuse, let existing = zoomState.snapshot {
            snapshot = existing
        } else {
            snapshot = tile.lendContent()
            snapshot.name = "snapshot"
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            snapshot.anchorPoint = .zero
            snapshot.position = tileRect.origin
            snapshot.opacity = inward ? 1 : 0
            zoomCover.layer?.addSublayer(snapshot)
            CATransaction.commit()
            zoomState.snapshot = snapshot
        }
        let stretch = CATransform3DMakeScale(full.width / tileRect.width, full.height / tileRect.height, 1)
        AgentMotion.animate(snapshot, "position", to: NSValue(point: to.origin), duration: duration, from: NSValue(point: from.origin))
        AgentMotion.animate(
            snapshot, "transform", to: inward ? stretch : CATransform3DIdentity, duration: duration,
            from: inward ? CATransform3DIdentity : stretch)
        // Out over the first 50 ms entering; in over the last 50 leaving. A
        // reversal keeps the holds, from what is on screen: the snapshot
        // never shows stretched over a large terminal.
        let snap = AgentMotion.snapFade / duration
        let shown = snapshot.presentation()?.opacity ?? snapshot.opacity
        snapshot.removeAnimation(forKey: "opacity")
        AgentMotion.animate(
            snapshot, "opacity", to: Float(inward ? 0 : 1), duration: duration, from: shown,
            hold: inward ? [(snap, Float(0))] : [(snap, Float(0)), (1 - snap, Float(0))])
    }

    /// The motion's end: every view at rest as the state says.
    private func endZoom() {
        let state = zoomState
        zoomState.agent = nil
        zoomState.settling = false
        zoomState.done = nil
        state.snapshot?.removeFromSuperlayer()
        zoomState.snapshot = nil
        state.tileView?.takeBackContent()
        state.tileView?.isZoomed = false
        zoomState.tileView = nil
        if let layer = screen.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for key in ["position", "bounds", "sublayerTransform", "cornerRadius"] { layer.removeAnimation(forKey: key) }
            layer.position = screen.frame.origin
            layer.bounds = CGRect(origin: .zero, size: screen.frame.size)
            layer.sublayerTransform = CATransform3DIdentity
            layer.cornerRadius = 10
            layer.masksToBounds = false
            CATransaction.commit()
        }
        setRegions(inside: isInside)
        if !isInside { state.done?() }
    }

    /// A motion for something else begins: this one ends where it was
    /// going, at once.
    func stopZoom() {
        guard zoomState.agent != nil else { return }
        zoomState.generation += 1
        endZoom()
    }
}
