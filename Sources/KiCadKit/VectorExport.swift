import Foundation

/// What to include in an export and how it looks.
public struct ExportOptions: Sendable {
    /// Layers to draw, bottom-most first.
    public var layers: [String]
    public var colors: [String: RGBA]
    public var showZoneFills: Bool = true
    public var showVias: Bool = true
    /// Footprints: pads, holes and footprint graphics.
    public var showComponents: Bool = true
    public var flipX: Bool = false
    public var flipY: Bool = false
    public var background: RGBA? = RGBA(0.07, 0.08, 0.09)
    public var substrate: RGBA = RGBA(0.11, 0.14, 0.13)
    public var viaColor: RGBA = RGBA(0.72, 0.72, 0.72)
    /// Margin around the board outline, mm.
    public var margin: Double = 3
    /// SVG: digits after the decimal point for coordinates (in mm).
    public var decimals: Int = 4
    /// Dimensions to draw, each with its label (e.g. "100.00 mm").
    public var dimensions: [(dimension: LinearDimension, label: String)] = []
    public var dimensionColor: RGBA = RGBA(0.9, 0.85, 0.4)
    /// SVG: turns a label into outline path data (mm, baseline at y = 0, starting at x = 0) and its width.
    /// When set, labels are written as curves instead of `<text>`.
    public var textToPath: (@Sendable (_ text: String, _ height: Double) -> (path: String, width: Double))?
    /// HP-GL: true for HP-GL/2 (BP header and pen widths), false for classic HP-GL.
    public var hpgl2: Bool = true

    public init(layers: [String], colors: [String: RGBA]) {
        self.layers = layers
        self.colors = colors
    }

    func color(_ layer: String) -> RGBA { colors[layer] ?? RGBA(0.6, 0.6, 0.6) }
}

extension Board {
    /// The area to export: the outline (or everything) plus the margin.
    func exportBounds(margin: Double) -> Rect {
        let b = outlineBounds
            ?? Rect.enclosing(pads.map(\.position) + tracks.flatMap { [$0.start, $0.end] })
            ?? Rect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        return Rect(minX: b.minX - margin, minY: b.minY - margin, maxX: b.maxX + margin, maxY: b.maxY + margin)
    }
}

// MARK: - SVG

public enum SVGExporter {
    /// An SVG drawing of the board in millimetres (the document is sized in mm).
    public static func svg(board: Board, options o: ExportOptions) -> String {
        let r = board.exportBounds(margin: o.margin)
        let fmtString = "%.\(max(0, min(8, o.decimals)))f"
        let fmt = { (v: Double) in String(format: fmtString, v) }
        // Flips mirror around the centre of the exported area.
        let sx = o.flipX ? -1.0 : 1.0, sy = o.flipY ? -1.0 : 1.0
        let cx = r.minX + r.width / 2, cy = r.minY + r.height / 2
        let transform = "translate(\(fmt(cx)) \(fmt(cy))) scale(\(fmt(sx)) \(fmt(sy))) translate(\(fmt(-cx)) \(fmt(-cy)))"

        func path(_ pts: [Point], closed: Bool) -> String {
            guard let f = pts.first else { return "" }
            var s = "M\(fmt(f.x)) \(fmt(f.y))"
            for p in pts.dropFirst() { s += "L\(fmt(p.x)) \(fmt(p.y))" }
            return closed ? s + "Z" : s
        }

        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(fmt(r.width))mm" height="\(fmt(r.height))mm" \
        viewBox="\(fmt(r.minX)) \(fmt(r.minY)) \(fmt(r.width)) \(fmt(r.height))">
        <title>\(xmlEscape(board.title ?? "Board"))</title>

        """
        if let bg = o.background {
            out += "<rect x=\"\(fmt(r.minX))\" y=\"\(fmt(r.minY))\" width=\"\(fmt(r.width))\" height=\"\(fmt(r.height))\" fill=\"\(bg.hex)\"/>\n"
        }
        out += "<g transform=\"\(transform)\">\n"
        if let outline = board.outlinePolygon {
            out += "<path id=\"substrate\" d=\"\(path(outline, closed: true))\" fill=\"\(o.substrate.hex)\"/>\n"
        }
        var anyCopper = false
        for layer in o.layers {
            let g = board.geometry(of: layer, includeFootprints: o.showComponents)
            if g.isEmpty { continue }
            if layer.hasSuffix(".Cu") { anyCopper = true }
            let c = o.color(layer)
            out += "<g id=\"\(xmlEscape(layer))\" fill=\"\(c.hex)\" stroke=\"\(c.hex)\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
            if o.showZoneFills, !g.zoneFills.isEmpty {
                out += "<path d=\"\(g.zoneFills.map { path($0, closed: true) }.joined())\" fill-opacity=\"0.4\" stroke=\"none\" fill-rule=\"evenodd\"/>\n"
            }
            for t in g.tracks {
                out += "<path d=\"\(path(t.points, closed: false))\" fill=\"none\" stroke-width=\"\(fmt(t.width))\"/>\n"
            }
            if !g.pads.isEmpty {
                out += "<path d=\"\(g.pads.map { path($0, closed: true) }.joined())\" stroke=\"none\"/>\n"
            }
            if !g.filledShapes.isEmpty {
                out += "<path d=\"\(g.filledShapes.map { path($0, closed: true) }.joined())\" stroke=\"none\"/>\n"
            }
            for l in g.lines {
                out += "<path d=\"\(path(l.points, closed: false))\" fill=\"none\" stroke-width=\"\(fmt(l.width))\"/>\n"
            }
            out += "</g>\n"
        }
        if anyCopper {
            if o.showVias {
                out += "<g id=\"vias\" fill=\"\(o.viaColor.hex)\">\n"
                for v in board.vias { out += "<circle cx=\"\(fmt(v.position.x))\" cy=\"\(fmt(v.position.y))\" r=\"\(fmt(v.size / 2))\"/>\n" }
                out += "</g>\n"
            }
            let holeColor = (o.background ?? RGBA(1, 1, 1)).hex
            out += "<g id=\"holes\" fill=\"\(holeColor)\">\n"
            for h in board.holes(includePads: o.showComponents) { out += "<circle cx=\"\(fmt(h.center.x))\" cy=\"\(fmt(h.center.y))\" r=\"\(fmt(h.diameter / 2))\"/>\n" }
            out += "</g>\n"
        }
        out += "</g>\n"
        out += dimensionsSVG(o, flip: { p in Point(o.flipX ? 2 * cx - p.x : p.x, o.flipY ? 2 * cy - p.y : p.y) }, fmt: fmt)
        out += "</svg>\n"
        return out
    }

    /// Dimension lines, arrows and labels, drawn outside the flip group so labels stay readable.
    static func dimensionsSVG(_ o: ExportOptions, flip: (Point) -> Point, fmt: (Double) -> String) -> String {
        guard !o.dimensions.isEmpty else { return "" }
        let c = o.dimensionColor.hex
        var out = "<g id=\"dimensions\" stroke=\"\(c)\" fill=\"\(c)\" stroke-width=\"0.15\">\n"
        let textHeight = 1.6, arrow = 1.2
        for (d, label) in o.dimensions {
            let geo = DimensionGeometry(d, arrow: arrow)
            for (a, b) in geo.lines {
                let p = flip(a), q = flip(b)
                out += "<line x1=\"\(fmt(p.x))\" y1=\"\(fmt(p.y))\" x2=\"\(fmt(q.x))\" y2=\"\(fmt(q.y))\"/>\n"
            }
            for tri in geo.arrows {
                let pts = tri.map(flip).map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
                out += "<polygon points=\"\(pts)\" stroke=\"none\"/>\n"
            }
            let mid = flip(geo.labelAt)
            let rotate = d.axis == .vertical ? " rotate(-90)" : ""
            if let toPath = o.textToPath {
                let t = toPath(label, textHeight)
                out += "<path transform=\"translate(\(fmt(mid.x)) \(fmt(mid.y)))\(rotate) translate(\(fmt(-t.width / 2)) \(fmt(-0.6)))\" d=\"\(t.path)\" stroke=\"none\"/>\n"
            } else {
                out += "<text transform=\"translate(\(fmt(mid.x)) \(fmt(mid.y)))\(rotate)\" y=\"-0.6\" text-anchor=\"middle\" font-family=\"Helvetica, Arial, sans-serif\" font-size=\"\(fmt(textHeight))\" stroke=\"none\">\(xmlEscape(label))</text>\n"
            }
        }
        return out + "</g>\n"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - HP-GL

public enum HPGLExporter {
    /// Plotter units per millimetre (HP-GL: 1 unit = 0.025 mm).
    public static let unitsPerMM = 40.0

    /// An HP-GL/2 plot of the board. Each layer gets its own pen (1–8, reused
    /// in turn); tracks and outlines are drawn with their real width (`PW`),
    /// pads and zone fills as outlines, holes as circles. Y points up as plotters expect.
    public static func hpgl(board: Board, options o: ExportOptions) -> String {
        let r = board.exportBounds(margin: o.margin)
        func pu(_ p: Point) -> (Int, Int) {
            var x = p.x - r.minX, y = r.maxY - p.y
            if o.flipX { x = r.width - x }
            if o.flipY { y = r.height - y }
            return (Int((x * unitsPerMM).rounded()), Int((y * unitsPerMM).rounded()))
        }
        var out = o.hpgl2 ? "BP;IN;\nSC;\nPU0,0;\n" : "IN;\nSC;\nPU0,0;\n"
        func pw(_ w: Double, _ pen: Int) { if o.hpgl2 { out += String(format: "PW%.3f,%d;\n", w, pen) } }
        func poly(_ pts: [Point], closed: Bool) {
            guard let f = pts.first else { return }
            let (x0, y0) = pu(f)
            out += "PU\(x0),\(y0);"
            let tail = Array(pts.dropFirst())
            let rest = (closed ? tail + [f] : tail).map { pu($0) }
            if !rest.isEmpty { out += "PD" + rest.map { "\($0.0),\($0.1)" }.joined(separator: ",") + ";" }
            out += "\n"
        }
        var anyCopper = false
        var pen = 0
        for layer in o.layers {
            let g = board.geometry(of: layer, includeFootprints: o.showComponents)
            if g.isEmpty { continue }
            if layer.hasSuffix(".Cu") { anyCopper = true }
            pen = pen % 8 + 1
            out += "CO \"\(layer)\";\nSP\(pen);\n"
            if o.showZoneFills {
                pw(0.1, pen)
                g.zoneFills.forEach { poly($0, closed: true) }
            }
            var width = -1.0
            for t in g.tracks {
                if t.width != width { width = t.width; pw(width, pen) }
                poly(t.points, closed: false)
            }
            pw(0.1, pen)
            g.pads.forEach { poly($0, closed: true) }
            g.filledShapes.forEach { poly($0, closed: true) }
            width = -1
            for l in g.lines {
                if l.width != width { width = l.width; pw(width, pen) }
                poly(l.points, closed: false)
            }
        }
        if anyCopper {
            pen = pen % 8 + 1
            out += "CO \"holes\";\nSP\(pen);\n"
            pw(0.1, pen)
            let vias: [(center: Point, diameter: Double)] = o.showVias ? board.vias.map { (center: $0.position, diameter: $0.size) } : []
            for h in vias + board.holes(includePads: o.showComponents) {
                let (x, y) = pu(h.center)
                out += String(format: "PU%d,%d;CI%d;\n", x, y, Int((h.diameter / 2 * unitsPerMM).rounded()))
            }
        }
        if !o.dimensions.isEmpty {
            pen = pen % 8 + 1
            out += "CO \"dimensions\";\nSP\(pen);\n"
            pw(0.15, pen)
            for (d, label) in o.dimensions {
                let geo = DimensionGeometry(d, arrow: 1.2)
                for (a, b) in geo.lines { poly([a, b], closed: false) }
                for tri in geo.arrows { poly(tri, closed: true) }
                let (x, y) = pu(geo.labelAt)
                // Character size in cm; DI turns vertical labels; LO4 centres the label on the point.
                out += d.axis == .vertical ? "DI0,1;" : "DI1,0;"
                out += "SI0.12,0.16;LO4;PU\(x),\(y);LB\(label)\u{3};\n"
            }
            out += "DI1,0;\n"
        }
        out += "PU;SP0;\n"
        return out
    }
}
