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
        let fmt = { (v: Double) in String(format: "%.4f", v) }
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
        out += "</g>\n</svg>\n"
        return out
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
        var out = "IN;\nSC;\nPU0,0;\n"
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
                out += "PW0.1,\(pen);\n"
                g.zoneFills.forEach { poly($0, closed: true) }
            }
            var width = -1.0
            for t in g.tracks {
                if t.width != width { width = t.width; out += String(format: "PW%.3f,%d;\n", width, pen) }
                poly(t.points, closed: false)
            }
            out += "PW0.1,\(pen);\n"
            g.pads.forEach { poly($0, closed: true) }
            g.filledShapes.forEach { poly($0, closed: true) }
            width = -1
            for l in g.lines {
                if l.width != width { width = l.width; out += String(format: "PW%.3f,%d;\n", width, pen) }
                poly(l.points, closed: false)
            }
        }
        if anyCopper {
            pen = pen % 8 + 1
            out += "CO \"holes\";\nSP\(pen);\nPW0.1,\(pen);\n"
            let vias: [(center: Point, diameter: Double)] = o.showVias ? board.vias.map { (center: $0.position, diameter: $0.size) } : []
            for h in vias + board.holes(includePads: o.showComponents) {
                let (x, y) = pu(h.center)
                out += String(format: "PU%d,%d;CI%d;\n", x, y, Int((h.diameter / 2 * unitsPerMM).rounded()))
            }
        }
        out += "PU;SP0;\n"
        return out
    }
}
