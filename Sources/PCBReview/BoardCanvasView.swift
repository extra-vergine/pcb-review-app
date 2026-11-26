import AppKit
import SwiftUI
import KiCadKit

/// The board drawing: layers, zoom (pinch, ⌘-scroll or mouse wheel), pan
/// (two-finger scroll or drag) and click to select.
struct BoardCanvasView: View {
    let board: Board
    @EnvironmentObject var model: BoardModel

    /// Pixels per millimetre.
    @State private var scale: CGFloat = 4
    /// Screen position of board coordinate (0, 0).
    @State private var offset: CGSize = .zero
    @State private var hover: Point?
    @State private var viewSize: CGSize = .zero

    static let background = Color(red: 0.07, green: 0.08, blue: 0.09)
    static let substrate = Color(red: 0.11, green: 0.14, blue: 0.13)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                canvas
                EventCaptureView(
                    onClick: { model.select(at: toBoard($0)) },
                    onDrag: { d in offset.width += d.width; offset.height += d.height },
                    onScroll: handleScroll,
                    onMagnify: { m, loc in zoom(by: 1 + m, at: loc) },
                    onHover: { hover = $0.map(toBoard) }
                )
                statusBar
            }
            .onAppear { viewSize = geo.size; fit() }
            .onChange(of: geo.size) { newSize in
                let old = viewSize
                viewSize = newSize
                if old == .zero { fit() }
            }
            .onChange(of: model.fitRequest) { _ in fit() }
        }
        .clipped()
    }

    // MARK: Drawing

    private var canvas: some View {
        let scene = model.scene
        let visible = model.visibleLayers
        let showFills = model.showZoneFills
        let showVias = model.showVias
        let highlight = model.highlight
        let scale = self.scale
        let offset = self.offset

        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.background))
            guard let scene else { return }
            var c = ctx
            c.concatenate(CGAffineTransform(translationX: offset.width, y: offset.height).scaledBy(x: scale, y: scale))

            let b = scene.bounds
            c.fill(Path(CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height)), with: .color(Self.substrate))

            let dim: Double = highlight?.net == nil ? 1 : 0.45
            var anyCopperVisible = false
            for layer in scene.drawOrder where visible.contains(layer) {
                guard let lp = scene.paths[layer] else { continue }
                let color = scene.color(of: layer)
                let isCopper = layer.hasSuffix(".Cu")
                if isCopper { anyCopperVisible = true }
                if showFills { c.fill(lp.zoneFills, with: .color(color.opacity(0.32 * dim))) }
                for g in lp.tracks {
                    c.stroke(g.path, with: .color(color.opacity(0.9 * dim)),
                             style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
                }
                c.fill(lp.pads, with: .color(color.opacity(0.95 * dim)))
                c.fill(lp.filledGraphics, with: .color(color.opacity(0.9)))
                for g in lp.graphics {
                    c.stroke(g.path, with: .color(color.opacity(0.9)),
                             style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
                }
            }

            if anyCopperVisible {
                if showVias { c.fill(scene.viaPaths, with: .color(Color(white: 0.72).opacity(dim))) }
                c.fill(scene.holes, with: .color(Self.background))
            }

            if let h = highlight {
                let glow = Color.white.opacity(0.55)
                for layer in scene.drawOrder where visible.contains(layer) {
                    guard let lp = h.netPaths[layer] else { continue }
                    for g in lp.tracks {
                        c.stroke(g.path, with: .color(glow), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
                    }
                    c.fill(lp.pads, with: .color(glow))
                }
                if showVias { c.fill(h.viaPaths, with: .color(glow)) }
                c.stroke(h.selectedOutline, with: .color(.cyan),
                         style: StrokeStyle(lineWidth: 2 / scale, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let p = hover {
                Text(String(format: "X %.3f  Y %.3f mm", p.x, p.y))
            }
            Text(String(format: "%.0f px/mm", scale))
            if let net = model.highlight?.net {
                Text("Net: \(net)")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        .padding(8)
        .allowsHitTesting(false)
    }

    // MARK: Navigation

    private func toBoard(_ p: CGPoint) -> Point {
        Point(Double((p.x - offset.width) / scale), Double((p.y - offset.height) / scale))
    }

    private func zoom(by factor: CGFloat, at location: CGPoint) {
        let newScale = min(max(scale * factor, 0.5), 3000)
        let k = newScale / scale
        offset.width = location.x - (location.x - offset.width) * k
        offset.height = location.y - (location.y - offset.height) * k
        scale = newScale
    }

    private func handleScroll(_ delta: CGSize, precise: Bool, zoomModifier: Bool, location: CGPoint) {
        if precise && !zoomModifier {
            offset.width += delta.width
            offset.height += delta.height
        } else {
            let speed: CGFloat = precise ? 0.01 : 0.1
            zoom(by: exp(delta.height * speed), at: location)
        }
    }

    private func fit() {
        guard let b = model.scene?.bounds, viewSize.width > 0, viewSize.height > 0, b.width > 0, b.height > 0 else { return }
        let s = min(viewSize.width / b.width, viewSize.height / b.height) * 0.92
        scale = s
        offset = CGSize(width: viewSize.width / 2 - (b.minX + b.width / 2) * s,
                        height: viewSize.height / 2 - (b.minY + b.height / 2) * s)
    }
}

/// A transparent AppKit view that turns mouse and trackpad events into callbacks.
/// SwiftUI alone has no scroll-wheel events on macOS 13.
struct EventCaptureView: NSViewRepresentable {
    var onClick: (CGPoint) -> Void
    var onDrag: (CGSize) -> Void
    var onScroll: (CGSize, _ precise: Bool, _ zoomModifier: Bool, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) { update(nsView) }

    private func update(_ v: CaptureView) {
        v.onClick = onClick
        v.onDrag = onDrag
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        v.onHover = onHover
    }

    final class CaptureView: NSView {
        var onClick: ((CGPoint) -> Void)?
        var onDrag: ((CGSize) -> Void)?
        var onScroll: ((CGSize, Bool, Bool, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onHover: ((CGPoint?) -> Void)?

        private var downLocation: CGPoint?
        private var lastDrag: CGPoint?
        private var dragged = false
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        private func location(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }

        override func mouseDown(with e: NSEvent) {
            let p = location(e)
            downLocation = p; lastDrag = p; dragged = false
        }

        override func mouseDragged(with e: NSEvent) {
            let p = location(e)
            if let down = downLocation, hypot(p.x - down.x, p.y - down.y) > 3 { dragged = true }
            if dragged, let last = lastDrag {
                onDrag?(CGSize(width: p.x - last.x, height: p.y - last.y))
                NSCursor.closedHand.set()
            }
            lastDrag = p
            onHover?(p)
        }

        override func mouseUp(with e: NSEvent) {
            if !dragged { onClick?(location(e)) }
            downLocation = nil; lastDrag = nil; dragged = false
            NSCursor.arrow.set()
        }

        override func mouseMoved(with e: NSEvent) { onHover?(location(e)) }
        override func mouseExited(with e: NSEvent) { onHover?(nil) }

        override func scrollWheel(with e: NSEvent) {
            let zoomKey = e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option)
            onScroll?(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY), e.hasPreciseScrollingDeltas, zoomKey, location(e))
        }

        override func magnify(with e: NSEvent) { onMagnify?(e.magnification, location(e)) }
    }
}
