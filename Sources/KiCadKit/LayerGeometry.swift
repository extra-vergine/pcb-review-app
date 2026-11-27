import Foundation

/// An sRGB colour with alpha, 0...1.
public struct RGBA: Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// `#rrggbb`.
    public var hex: String {
        func c(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }
}

/// What one layer contains, as plain geometry in board coordinates (mm).
/// Used by the vector exporters.
public struct LayerGeometry: Sendable {
    public struct Stroke: Sendable {
        public var points: [Point]
        public var width: Double
    }
    public var zoneFills: [[Point]] = []
    public var tracks: [Stroke] = []
    public var pads: [[Point]] = []
    public var lines: [Stroke] = []
    public var filledShapes: [[Point]] = []

    public var isEmpty: Bool {
        zoneFills.isEmpty && tracks.isEmpty && pads.isEmpty && lines.isEmpty && filledShapes.isEmpty
    }
}

public extension Board {
    /// The geometry on `layer`: zone fills, tracks, pads and graphics (board and footprint).
    func geometry(of layer: String, includeFootprints: Bool = true) -> LayerGeometry {
        var g = LayerGeometry()
        for z in zones where !z.isRuleArea {
            for f in z.filledPolygons where f.layer == layer { g.zoneFills.append(f.points) }
        }
        for t in tracks where t.layer == layer { g.tracks.append(.init(points: t.centerline, width: t.width)) }
        if includeFootprints {
            for p in pads where p.copperLayers.contains(layer) { g.pads.append(p.outline) }
        }
        let footprintGraphics = footprints.flatMap(\.graphics).filter { includeFootprints || $0.layer == "Edge.Cuts" }
        for gr in graphics + footprintGraphics where gr.layer == layer {
            if gr.filled, gr.kind == .polygon || gr.kind == .rect || gr.kind == .circle {
                g.filledShapes.append(gr.polyline)
            }
            g.lines.append(.init(points: gr.polyline, width: max(gr.width, 0.01)))
        }
        return g
    }

    /// Hole centres and diameters for pads and vias (slots use their smaller size).
    var holes: [(center: Point, diameter: Double)] { holes(includePads: true) }

    /// Hole centres and diameters; pad holes only when `includePads`.
    func holes(includePads: Bool) -> [(center: Point, diameter: Double)] {
        let padHoles: [(center: Point, diameter: Double)] = !includePads ? [] : pads.compactMap { p in
            guard let d = p.drill else { return nil }
            return (center: p.position, diameter: d.minimumSize)
        }
        let viaHoles: [(center: Point, diameter: Double)] = vias.map { (center: $0.position, diameter: $0.drill) }
        return padHoles + viaHoles
    }

    /// The board outline as one closed polygon: the `Edge.Cuts` lines and arcs
    /// chained end to end. Returns the largest loop when there are several
    /// (cut-outs are ignored), or nil if the outline does not close.
    var outlinePolygon: [Point]? {
        var pieces: [[Point]] = []
        for g in outline {
            switch g.kind {
            case .rect, .circle, .polygon:
                let pl = g.polyline
                if pl.count > 2 { pieces.append(pl) }   // already closed
            default:
                let pl = g.polyline
                if pl.count > 1 { pieces.append(pl) }
            }
        }
        let tol = 0.01
        var loops: [[Point]] = []
        var open: [[Point]] = []
        for p in pieces {
            if let f = p.first, let l = p.last, f.distance(to: l) < tol, p.count > 3 { loops.append(p) } else { open.append(p) }
        }
        while var chain = open.popLast() {
            var progressed = true
            while progressed, let end = chain.last, let start = chain.first, end.distance(to: start) >= tol {
                progressed = false
                for (i, p) in open.enumerated() {
                    if let f = p.first, f.distance(to: end) < tol {
                        chain += p.dropFirst(); open.remove(at: i); progressed = true; break
                    }
                    if let l = p.last, l.distance(to: end) < tol {
                        chain += p.reversed().dropFirst(); open.remove(at: i); progressed = true; break
                    }
                }
            }
            if let f = chain.first, let l = chain.last, f.distance(to: l) < tol { loops.append(chain) }
        }
        func area(_ p: [Point]) -> Double { abs(Polygon.signedArea(p)) }
        guard var best = loops.max(by: { area($0) < area($1) }) else { return nil }
        if let f = best.first, let l = best.last, f.distance(to: l) < tol { best.removeLast() }
        return best
    }
}

public enum Polygon {
    /// Shoelace area; positive for counter-clockwise in a Y-up frame.
    public static func signedArea(_ p: [Point]) -> Double {
        guard p.count > 2 else { return 0 }
        var s = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    /// Ear-clipping triangulation of a simple polygon. Returns index triples
    /// into `p`, wound the same way as `p`.
    public static func triangulate(_ p: [Point]) -> [Int] {
        let n = p.count
        guard n >= 3 else { return [] }
        var idx = Array(0..<n)
        let ccw = signedArea(p) > 0
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        func isConvex(_ a: Point, _ b: Point, _ c: Point) -> Bool { ccw ? cross(a, b, c) > 1e-12 : cross(a, b, c) < -1e-12 }
        func inside(_ q: Point, _ a: Point, _ b: Point, _ c: Point) -> Bool {
            let d1 = cross(a, b, q), d2 = cross(b, c, q), d3 = cross(c, a, q)
            let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
            return !(neg && pos)
        }
        var out: [Int] = []
        var guardCount = 0
        while idx.count > 3, guardCount < n * n {
            guardCount += 1
            var clipped = false
            for i in 0..<idx.count {
                let ia = idx[(i + idx.count - 1) % idx.count], ib = idx[i], ic = idx[(i + 1) % idx.count]
                let a = p[ia], b = p[ib], c = p[ic]
                guard isConvex(a, b, c) else { continue }
                var ear = true
                for j in idx where j != ia && j != ib && j != ic {
                    if inside(p[j], a, b, c) { ear = false; break }
                }
                if ear {
                    out += [ia, ib, ic]
                    idx.remove(at: i)
                    clipped = true
                    break
                }
            }
            if !clipped { break } // degenerate input; return what we have
        }
        if idx.count == 3 { out += idx }
        return out
    }
}
