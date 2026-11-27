import Foundation

/// Copper or hole geometry reduced to what the clearance checks need: a set
/// of segments widened by `radius`, and for polygon pads the polygon itself so
/// that overlap can be detected.
struct CheckShape {
    var segments: [(Point, Point)]
    var radius: Double
    /// Closed outline for containment tests (polygon pads only).
    var polygon: [Point]?
    var bounds: Rect

    init(segments: [(Point, Point)], radius: Double, polygon: [Point]? = nil) {
        self.segments = segments
        self.radius = radius
        self.polygon = polygon
        let pts = segments.flatMap { [$0.0, $0.1] } + (polygon ?? [])
        var b = Rect.enclosing(pts) ?? Rect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        b.minX -= radius; b.minY -= radius; b.maxX += radius; b.maxY += radius
        bounds = b
    }

    static func circle(_ c: Point, radius: Double) -> CheckShape { CheckShape(segments: [(c, c)], radius: radius) }

    static func polyline(_ pts: [Point], radius: Double) -> CheckShape {
        if pts.count < 2 { return .circle(pts.first ?? Point(0, 0), radius: radius) }
        return CheckShape(segments: zip(pts, pts.dropFirst()).map { ($0, $1) }, radius: radius)
    }

    static func polygon(_ pts: [Point]) -> CheckShape {
        guard let first = pts.first else { return .circle(Point(0, 0), radius: 0) }
        let closed = pts + [first]
        return CheckShape(segments: zip(closed, closed.dropFirst()).map { ($0, $1) }, radius: 0, polygon: pts)
    }

    /// The copper of a pad: a circle, a stadium for ovals, else its outline polygon.
    static func pad(_ p: Pad) -> CheckShape {
        let w = p.size.width, h = p.size.height
        switch p.shape {
        case .circle:
            return .circle(p.position, radius: w / 2)
        case .oval where abs(w - h) < 1e-9:
            return .circle(p.position, radius: w / 2)
        case .oval:
            let half = abs(w - h) / 2
            let axis = w > h ? Point(half, 0) : Point(0, half)
            let a = Point(-axis.x, -axis.y).rotated(byDegrees: p.rotation) + p.position
            let b = axis.rotated(byDegrees: p.rotation) + p.position
            return CheckShape(segments: [(a, b)], radius: min(w, h) / 2)
        default:
            return .polygon(p.outline)
        }
    }

    /// The hole of a pad: a circle, or a stadium for a slot.
    static func hole(of p: Pad) -> CheckShape? {
        guard let d = p.drill else { return nil }
        let c = p.position + (d.offset ?? Point(0, 0)).rotated(byDegrees: p.rotation)
        guard let sh = d.slotHeight, abs(sh - d.diameter) > 1e-9 else { return .circle(c, radius: d.diameter / 2) }
        let half = abs(d.diameter - sh) / 2
        let axis = d.diameter > sh ? Point(half, 0) : Point(0, half)
        let a = Point(-axis.x, -axis.y).rotated(byDegrees: p.rotation) + c
        let b = axis.rotated(byDegrees: p.rotation) + c
        return CheckShape(segments: [(a, b)], radius: min(d.diameter, sh) / 2)
    }

    /// Gap between the two shapes (0 when they touch or overlap), and the
    /// point halfway across the gap.
    static func gap(_ s: CheckShape, _ t: CheckShape) -> (distance: Double, at: Point) {
        var best = Double.infinity
        var at = Point(0, 0)
        for (a, b) in s.segments {
            for (c, d) in t.segments {
                let r = Geometry2D.segmentDistance(a, b, c, d)
                if r.distance < best {
                    best = r.distance
                    at = Point((r.p.x + r.q.x) / 2, (r.p.y + r.q.y) / 2)
                }
            }
        }
        if let poly = s.polygon, let p = t.segments.first?.0, Shapes.contains(poly, p) { return (0, p) }
        if let poly = t.polygon, let p = s.segments.first?.0, Shapes.contains(poly, p) { return (0, p) }
        return (max(0, best - s.radius - t.radius), at)
    }
}

enum Geometry2D {
    /// Closest points between segments a–b and c–d.
    static func segmentDistance(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> (distance: Double, p: Point, q: Point) {
        if segmentsIntersect(a, b, c, d) {
            let p = intersection(a, b, c, d) ?? a
            return (0, p, p)
        }
        var best = (distance: Double.infinity, p: a, q: c)
        func consider(_ p: Point, onto s0: Point, _ s1: Point, pointFirst: Bool) {
            let q = closest(p, s0, s1)
            let dist = p.distance(to: q)
            if dist < best.distance { best = pointFirst ? (dist, p, q) : (dist, q, p) }
        }
        consider(a, onto: c, d, pointFirst: true)
        consider(b, onto: c, d, pointFirst: true)
        consider(c, onto: a, b, pointFirst: false)
        consider(d, onto: a, b, pointFirst: false)
        return best
    }

    static func closest(_ p: Point, _ a: Point, _ b: Point) -> Point {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return Point(a.x + t * dx, a.y + t * dy)
    }

    private static func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    static func intersection(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Point? {
        let r = Point(b.x - a.x, b.y - a.y), s = Point(d.x - c.x, d.y - c.y)
        let den = r.x * s.y - r.y * s.x
        guard abs(den) > 1e-15 else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / den
        return Point(a.x + t * r.x, a.y + t * r.y)
    }
}

/// A uniform grid over shape bounds, for finding shapes near each other.
struct SpatialGrid {
    let cell: Double
    private var cells: [Int64: [Int]] = [:]

    init(cell: Double) { self.cell = max(cell, 0.1) }

    private func key(_ ix: Int, _ iy: Int) -> Int64 { Int64(ix) << 32 | Int64(UInt32(bitPattern: Int32(iy))) }
    private func range(_ r: Rect) -> (ClosedRange<Int>, ClosedRange<Int>) {
        (Int((r.minX / cell).rounded(.down))...Int((r.maxX / cell).rounded(.down)),
         Int((r.minY / cell).rounded(.down))...Int((r.maxY / cell).rounded(.down)))
    }

    mutating func insert(_ index: Int, bounds: Rect) {
        let (xs, ys) = range(bounds)
        for ix in xs { for iy in ys { cells[key(ix, iy), default: []].append(index) } }
    }

    /// Indices whose bounds may lie within `margin` of `bounds` (may repeat).
    func query(_ bounds: Rect, margin: Double) -> [Int] {
        let r = Rect(minX: bounds.minX - margin, minY: bounds.minY - margin, maxX: bounds.maxX + margin, maxY: bounds.maxY + margin)
        let (xs, ys) = range(r)
        var out: [Int] = []
        for ix in xs { for iy in ys { if let c = cells[key(ix, iy)] { out.append(contentsOf: c) } } }
        return out
    }
}

public extension Rect {
    func overlaps(_ o: Rect, margin: Double = 0) -> Bool {
        minX - margin <= o.maxX && o.minX - margin <= maxX && minY - margin <= o.maxY && o.minY - margin <= maxY
    }
    func union(_ o: Rect) -> Rect {
        Rect(minX: Swift.min(minX, o.minX), minY: Swift.min(minY, o.minY), maxX: Swift.max(maxX, o.maxX), maxY: Swift.max(maxY, o.maxY))
    }
    var center: Point { Point((minX + maxX) / 2, (minY + maxY) / 2) }
}
