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
                    onClick: handleClick,
                    onDrag: { viewport.pan(by: $0) },
                    onScroll: handleScroll,
                    onMagnify: { m, loc in viewport.zoom(by: 1 + m, at: loc) },
                    onHover: { viewport.hover = $0.map(viewport.toBoard) },
                    onPress: { model.grabGuide(at: $0, transform: viewport.transform) },
                    onPressDrag: { model.moveGuide(to: $0, transform: viewport.transform) },
                    onPressEnd: { model.endGuideDrag(at: $0, rulerSize: Self.rulerSize) }
                )
                if model.showRulers {
                    RulersView(origin: model.userOrigin)
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
        .coordinateSpace(name: Self.space)
        .clipped()
    }

    static let space = "boardCanvas"

    private func fit() {
        if let b = model.fitRect { viewport.fit(b) }
    }

    /// A click on the origin marker moves the origin to the next corner; anywhere else selects.
    private func handleClick(_ p: CGPoint) {
        if model.showOrigin {
            let o = viewport.toScreen(model.userOrigin)
            if hypot(o.x - p.x, o.y - p.y) <= 12 {
                model.cycleOrigin()
                return
            }
        }
        model.select(at: viewport.toBoard(p))
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
        let origin: Point? = model.showOrigin ? model.userOrigin : nil
        let dimColor = model.color(of: BoardModel.drawingsLayer)
        let t = viewport.transform
        let guides = model.guides + (model.pendingGuide.map { [$0] } ?? [])
        let guideOrigin = model.userOrigin
        let inset = model.showRulers ? Self.rulerSize : 0
        return Canvas { ctx, size in
            GuideRenderer.draw(guides, in: ctx, size: size, transform: t, origin: guideOrigin, units: units, inset: inset)
            BoardRenderer.drawOverlay(in: ctx, transform: t, origin: origin, dimensions: dims,
                                      dimensionColor: dimColor, units: units)
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        let units = model.units
        let origin = model.userOrigin
        return HStack(spacing: 12) {
            if let p = viewport.hover {
                // Relative to the origin, with Y pointing up.
                Text("X \(units.format(p.x - origin.x, withUnit: false))  Y \(units.format(origin.y - p.y, withUnit: false)) \(units.rawValue)")
            }
            if model.showOrigin {
                Text("Origin: \(model.originDescription)")
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
        ctx.stroke(ext, with: .color(color.opacity(0.85)), lineWidth: 1)

        var line = Path()
        line.move(to: sa); line.addLine(to: sb)
        ctx.stroke(line, with: .color(color), lineWidth: 1.5)

        // Arrow heads pointing outwards to the extension lines.
        let dx = sb.x - sa.x, dy = sb.y - sa.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        func arrow(at p: CGPoint, dir: CGFloat) -> Path {
            var path = Path()
            let size: CGFloat = 13, half: CGFloat = 4.5
            let back = CGPoint(x: p.x + ux * size * dir, y: p.y + uy * size * dir)
            path.move(to: p)
            path.addLine(to: CGPoint(x: back.x - uy * half, y: back.y + ux * half))
            path.addLine(to: CGPoint(x: back.x + uy * half, y: back.y - ux * half))
            path.closeSubpath()
            return path
        }
        if len > 34 {
            ctx.fill(arrow(at: sa, dir: 1), with: .color(color))
            ctx.fill(arrow(at: sb, dir: -1), with: .color(color))
        }

        // Label, outside the board: above horizontal lines, left of vertical ones on the left side.
        let label = Text(units.format(d.length))
            .font(.system(size: 16, weight: .semibold).monospacedDigit())
            .foregroundColor(color)
        let mid = CGPoint(x: (sa.x + sb.x) / 2, y: (sa.y + sb.y) / 2)
        if horizontal {
            ctx.draw(label, at: CGPoint(x: mid.x, y: mid.y - 4), anchor: .bottom)
        } else {
            var t = ctx
            t.translateBy(x: mid.x - 4, y: mid.y)
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
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardCanvasView.space))
                .onChanged { v in
                    let p = viewport.toBoard(v.location)
                    model.pendingGuide = horizontal
                        ? Guide(axis: .horizontal, position: p.y)
                        : Guide(axis: .vertical, position: p.x)
                }
                .onEnded { v in
                    // Place the guide only if it was dragged out onto the board view.
                    let onBoard = horizontal ? v.location.y > thickness : v.location.x > thickness
                    if onBoard, let g = model.pendingGuide { model.guides.append(g) }
                    model.pendingGuide = nil
                }
        )
        .help("Click to switch units (mm → in → pt → mil). Drag onto the board for a guide.")
    }
}

/// Draws guides as blue dashed lines across the canvas, with their position next to the ruler.
enum GuideRenderer {
    static let color = Color(red: 0.25, green: 0.56, blue: 1.0)

    static func draw(_ guides: [Guide], in ctx: GraphicsContext, size: CGSize, transform t: ViewTransform,
                     origin: Point, units: LengthUnit, inset: CGFloat) {
        let style = StrokeStyle(lineWidth: 1, dash: [6, 4])
        for g in guides {
            var path = Path()
            let label: String
            let at: CGPoint
            switch g.axis {
            case .horizontal:
                let y = t.screen(Point(0, g.position)).y
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                label = units.format(origin.y - g.position)
                at = CGPoint(x: inset + 4, y: y - 2)
            case .vertical:
                let x = t.screen(Point(g.position, 0)).x
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                label = units.format(g.position - origin.x)
                at = CGPoint(x: x + 4, y: inset + 2)
            }
            ctx.stroke(path, with: .color(color), style: style)
            let text = Text(label).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundColor(color)
            ctx.draw(text, at: at, anchor: g.axis == .horizontal ? .bottomLeading : .topLeading)
        }
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
    /// Called on mouse down; returning true routes the drag to `onPressDrag` / `onPressEnd` (guides).
    var onPress: (CGPoint) -> Bool = { _ in false }
    var onPressDrag: (CGPoint) -> Void = { _ in }
    var onPressEnd: (CGPoint) -> Void = { _ in }

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
        v.onPress = onPress
        v.onPressDrag = onPressDrag
        v.onPressEnd = onPressEnd
    }

    final class CaptureView: NSView {
        var onClick: ((CGPoint) -> Void)?
        var onDrag: ((CGSize) -> Void)?
        var onScroll: ((CGSize, Bool, Bool, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onHover: ((CGPoint?) -> Void)?
        var onPress: ((CGPoint) -> Bool)?
        var onPressDrag: ((CGPoint) -> Void)?
        var onPressEnd: ((CGPoint) -> Void)?
        private var pressing = false

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
            pressing = onPress?(p) ?? false
            if pressing { NSCursor.resizeLeftRight.set() }
        }

        override func mouseDragged(with e: NSEvent) {
            let p = location(e)
            if pressing {
                onPressDrag?(p)
                onHover?(p)
                return
            }
            if let down = downLocation, hypot(p.x - down.x, p.y - down.y) > 3 { dragged = true }
            if dragged, let last = lastDrag {
                onDrag?(CGSize(width: p.x - last.x, height: p.y - last.y))
                NSCursor.closedHand.set()
            }
            lastDrag = p
            onHover?(p)
        }

        override func mouseUp(with e: NSEvent) {
            if pressing {
                onPressEnd?(location(e))
                pressing = false
                NSCursor.arrow.set()
                return
            }
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
