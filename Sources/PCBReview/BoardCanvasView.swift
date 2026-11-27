import AppKit
import SwiftUI
import KiCadKit

/// The board drawing: layers, zoom (pinch, ⌘-scroll, mouse wheel, ⌘+ / ⌘−),
/// pan (two-finger scroll, drag or arrow keys), click to select, rulers, origin and dimensions.
struct BoardCanvasView: View {
    let board: Board
    @EnvironmentObject var model: BoardModel
    @EnvironmentObject var viewport: Viewport
    @State private var keyMonitor: Any?

    static let rulerSize: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                boardCanvas
                overlayCanvas
                    .allowsHitTesting(false)
                EventCaptureView(
                    onClick: { model.select(at: viewport.toBoard($0)) },
                    onDrag: { viewport.pan(by: $0) },
                    onScroll: handleScroll,
                    onMagnify: { m, loc in viewport.zoom(by: 1 + m, at: loc) },
                    onHover: { viewport.hover = $0.map(viewport.toBoard) }
                )
                if model.showRulers {
                    RulersView(origin: board.userOrigin)
                }
                statusBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .onAppear {
                viewport.size = geo.size
                fit()
                installKeyMonitor()
            }
            .onDisappear(perform: removeKeyMonitor)
            .onChange(of: geo.size) { newSize in
                let first = viewport.size == .zero
                viewport.size = newSize
                if first { fit() }
            }
            .onChange(of: model.fitRequest) { _ in fit() }
        }
        .clipped()
    }

    private func fit() {
        if let b = model.scene?.bounds { viewport.fit(b) }
    }

    private func handleScroll(_ delta: CGSize, precise: Bool, zoomModifier: Bool, location: CGPoint) {
        if precise && !zoomModifier {
            viewport.pan(by: delta)
        } else {
            let speed: CGFloat = precise ? 0.01 : 0.1
            viewport.zoom(by: exp(delta.height * speed), at: location)
        }
    }

    /// Arrow keys move the board (Shift moves further), unless a text field has focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [viewport] event in
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { return event }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 200 : 40
            switch event.keyCode {
            case 123: viewport.pan(by: CGSize(width: -step, height: 0))   // left
            case 124: viewport.pan(by: CGSize(width: step, height: 0))    // right
            case 125: viewport.pan(by: CGSize(width: 0, height: step))    // down
            case 126: viewport.pan(by: CGSize(width: 0, height: -step))   // up
            default: return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    // MARK: Drawing

    private var boardCanvas: some View {
        let scene = model.scene
        let options = model.renderOptions
        let t = viewport.transform
        return Canvas { ctx, size in
            if let scene {
                BoardRenderer.draw(scene, in: ctx, size: size, transform: t, options: options)
            } else {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RenderOptions.background))
            }
        }
    }

    private var overlayCanvas: some View {
        let dims = model.dimensions
        let units = model.units
        let origin: Point? = model.showOrigin ? board.userOrigin : nil
        let dimColor = model.color(of: BoardModel.drawingsLayer)
        let t = viewport.transform
        return Canvas { ctx, _ in
            BoardRenderer.drawOverlay(in: ctx, transform: t, origin: origin, dimensions: dims,
                                      dimensionColor: dimColor, units: units)
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        let units = model.units
        let origin = board.userOrigin
        return HStack(spacing: 12) {
            if let p = viewport.hover {
                // Relative to the origin, with Y pointing up.
                Text("X \(units.format(p.x - origin.x, withUnit: false))  Y \(units.format(origin.y - p.y, withUnit: false)) \(units.rawValue)")
            }
            Text(String(format: "%.0f px/mm", viewport.scale))
            if viewport.flipX || viewport.flipY {
                Text(viewport.flipX && viewport.flipY ? "Flipped X+Y" : viewport.flipX ? "Flipped X" : "Flipped Y")
            }
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
}

/// Draws one linear dimension KiCad-style: extension lines, a dimension line
/// with arrows, and the length as text.
enum DimensionRenderer {
    static func draw(_ d: LinearDimension, in ctx: GraphicsContext, color: Color, units: LengthUnit,
                     toScreen: (Point) -> CGPoint) {
        let horizontal = d.axis == .horizontal
        // Dimension line end points on the board.
        let a = horizontal ? Point(d.from.x, d.lineAt) : Point(d.lineAt, d.from.y)
        let b = horizontal ? Point(d.to.x, d.lineAt) : Point(d.lineAt, d.to.y)
        let sa = toScreen(a), sb = toScreen(b)
        let fa = toScreen(d.from), fb = toScreen(d.to)

        // Extension lines from just off each feature to a little past the dimension line.
        var ext = Path()
        for (f, s) in [(fa, sa), (fb, sb)] {
            let dx = s.x - f.x, dy = s.y - f.y
            let len = max(hypot(dx, dy), 0.001)
            let ux = dx / len, uy = dy / len
            ext.move(to: CGPoint(x: f.x + ux * 4, y: f.y + uy * 4))
            ext.addLine(to: CGPoint(x: s.x + ux * 6, y: s.y + uy * 6))
        }
        ctx.stroke(ext, with: .color(color.opacity(0.8)), lineWidth: 0.8)

        var line = Path()
        line.move(to: sa); line.addLine(to: sb)
        ctx.stroke(line, with: .color(color), lineWidth: 1)

        // Arrow heads pointing outwards to the extension lines.
        let dx = sb.x - sa.x, dy = sb.y - sa.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        func arrow(at p: CGPoint, dir: CGFloat) -> Path {
            var path = Path()
            let size: CGFloat = 7, half: CGFloat = 2.6
            let back = CGPoint(x: p.x + ux * size * dir, y: p.y + uy * size * dir)
            path.move(to: p)
            path.addLine(to: CGPoint(x: back.x - uy * half, y: back.y + ux * half))
            path.addLine(to: CGPoint(x: back.x + uy * half, y: back.y - ux * half))
            path.closeSubpath()
            return path
        }
        if len > 20 {
            ctx.fill(arrow(at: sa, dir: 1), with: .color(color))
            ctx.fill(arrow(at: sb, dir: -1), with: .color(color))
        }

        // Label, outside the board: above horizontal lines, left of vertical ones on the left side.
        let label = Text(units.format(d.length))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(color)
        let mid = CGPoint(x: (sa.x + sb.x) / 2, y: (sa.y + sb.y) / 2)
        if horizontal {
            ctx.draw(label, at: CGPoint(x: mid.x, y: mid.y - 3), anchor: .bottom)
        } else {
            var t = ctx
            t.translateBy(x: mid.x - 3, y: mid.y)
            t.rotate(by: .degrees(-90))
            t.draw(label, at: .zero, anchor: .bottom)
        }
    }
}

/// Top and left rulers. Values are relative to the board origin, X to the
/// right and Y up. Click a ruler to switch units (mm → in → pt → mil).
struct RulersView: View {
    let origin: Point
    @EnvironmentObject var model: BoardModel
    @EnvironmentObject var viewport: Viewport

    private let thickness = BoardCanvasView.rulerSize
    private static let fill = Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.94)
    private static let ink = Color.white.opacity(0.75)
    private static let accent = Color(red: 0.35, green: 0.85, blue: 0.95)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ruler(horizontal: true)
                .frame(height: thickness)
                .padding(.leading, thickness)
            ruler(horizontal: false)
                .frame(width: thickness)
                .padding(.top, thickness)
            Text(model.units.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Self.accent)
                .frame(width: thickness, height: thickness)
                .background(Self.fill)
                .contentShape(Rectangle())
                .onTapGesture { model.units = model.units.next }
                .help("Click a ruler to switch units")
        }
    }

    private func ruler(horizontal: Bool) -> some View {
        let unit = model.units
        let t = viewport.transform
        let hover = viewport.hover
        let origin = self.origin
        let thickness = self.thickness

        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.fill))
            let mmPerUnit = unit.millimetres
            let pxPerUnit = Double(t.scale) * mmPerUnit
            let major = RulerTicks.step(pixelsPerUnit: pxPerUnit, minSpacing: 70)
            let minor = RulerTicks.minor(for: major)
            // The ruler's own drawing starts after the corner square.
            let shift = Double(thickness)
            let length = Double(horizontal ? size.width : size.height)

            // Ruler coordinate of a value in units, and back. X to the right, Y up, from the origin.
            func pos(_ u: Double) -> Double {
                if horizontal {
                    return Double(t.screen(Point(origin.x + u * mmPerUnit, 0)).x) - shift
                } else {
                    return Double(t.screen(Point(0, origin.y - u * mmPerUnit)).y) - shift
                }
            }
            func value(at r: Double) -> Double {
                if horizontal {
                    return (t.board(CGPoint(x: r + shift, y: 0)).x - origin.x) / mmPerUnit
                } else {
                    return (origin.y - t.board(CGPoint(x: 0, y: r + shift)).y) / mmPerUnit
                }
            }
            let u0 = value(at: 0), u1 = value(at: length)
            let lo = min(u0, u1), hi = max(u0, u1)
            let ratio = max(1, Int((major / minor).rounded()))
            var k = Int((lo / minor).rounded(.down))
            let kEnd = Int((hi / minor).rounded(.up))
            var ticks = Path()
            let decimals = RulerTicks.decimals(for: major)
            while k <= kEnd {
                let u = Double(k) * minor
                let p = CGFloat(pos(u))
                let isMajor = k % ratio == 0
                let tick: CGFloat = isMajor ? thickness * 0.55 : thickness * 0.25
                if horizontal {
                    ticks.move(to: CGPoint(x: p, y: thickness)); ticks.addLine(to: CGPoint(x: p, y: thickness - tick))
                } else {
                    ticks.move(to: CGPoint(x: thickness, y: p)); ticks.addLine(to: CGPoint(x: thickness - tick, y: p))
                }
                if isMajor {
                    let text = Text(String(format: "%.\(decimals)f", abs(u) < 1e-9 ? 0 : u))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(Self.ink)
                    if horizontal {
                        ctx.draw(text, at: CGPoint(x: p + 3, y: 2), anchor: .topLeading)
                    } else {
                        var c = ctx
                        c.translateBy(x: 2, y: p - 3)
                        c.rotate(by: .degrees(-90))
                        c.draw(text, at: .zero, anchor: .topLeading)
                    }
                }
                k += 1
            }
            ctx.stroke(ticks, with: .color(Self.ink), lineWidth: 1)

            // Cursor marker.
            if let h = hover {
                let s = t.screen(h)
                let p = (horizontal ? s.x : s.y) - CGFloat(shift)
                var m = Path()
                if horizontal { m.move(to: CGPoint(x: p, y: 0)); m.addLine(to: CGPoint(x: p, y: thickness)) }
                else { m.move(to: CGPoint(x: 0, y: p)); m.addLine(to: CGPoint(x: thickness, y: p)) }
                ctx.stroke(m, with: .color(Self.accent), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.units = model.units.next }
        .help("Click to switch units: mm → in → pt → mil")
    }
}

enum RulerTicks {
    /// A 1-2-5 step in units so that major ticks are at least `minSpacing` points apart.
    static func step(pixelsPerUnit: Double, minSpacing: Double) -> Double {
        guard pixelsPerUnit > 0 else { return 1 }
        let raw = minSpacing / pixelsPerUnit
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        for m in [1.0, 2.0, 5.0, 10.0] where m * base >= raw { return m * base }
        return 10 * base
    }

    static func minor(for major: Double) -> Double {
        let mantissa = major / pow(10, floor(log10(major)))
        return major / (abs(mantissa - 2) < 0.01 ? 4 : 5)
    }

    static func decimals(for step: Double) -> Int {
        max(0, Int(-floor(log10(step) + 1e-9)))
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
