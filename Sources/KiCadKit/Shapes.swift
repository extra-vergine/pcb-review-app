import Foundation

/// Geometry helpers shared by the board view and the rule checks.
public enum Shapes {
    /// Centre and radius of the circle through three points, or nil if they are collinear.
    public static func circle(through a: Point, _ b: Point, _ c: Point) -> (center: Point, radius: Double)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-12 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        let center = Point(ux, uy)
        return (center, center.distance(to: a))
    }

    /// Points along the arc from `start` through `mid` to `end`, at most `maxError` mm from the true arc.
    /// Falls back to a straight line when the points are collinear.
    public static func arcPoints(start: Point, mid: Point, end: Point, maxError: Double = 0.005) -> [Point] {
        guard let circ = circle(through: start, mid, end), circ.radius > 0 else { return [start, end] }
        let c = circ.center, r = circ.radius
        let a0 = atan2(start.y - c.y, start.x - c.x)
        var a1 = atan2(mid.y - c.y, mid.x - c.x)
        var a2 = atan2(end.y - c.y, end.x - c.x)
        // Unwrap so that a0 -> a1 -> a2 is monotonic.
        func unwrap(_ a: Double, near ref: Double, positive: Bool) -> Double {
            var x = a
            if positive { while x < ref { x += 2 * .pi } } else { while x > ref { x -= 2 * .pi } }
            return x
        }
        let ccw = { () -> Bool in
            let m = unwrap(a1, near: a0, positive: true)
            let e = unwrap(a2, near: a0, positive: true)
            return m < e
        }()
        a1 = unwrap(a1, near: a0, positive: ccw)
        a2 = unwrap(a2, near: a0, positive: ccw)
        let sweep = a2 - a0
        let step = 2 * acos(max(-1, min(1, 1 - maxError / r)))
        let n = max(2, Int((abs(sweep) / max(step, 1e-3)).rounded(.up)))
        return (0...n).map { i in
            let t = a0 + sweep * Double(i) / Double(n)
            return Point(c.x + r * cos(t), c.y + r * sin(t))
        }
    }

    /// An oval (stadium) outline, e.g. for a slotted hole.
    public static func oval(center: Point, width: Double, height: Double, rotation: Double) -> [Point] {
        Pad.roundedRect(w: width, h: height, radius: min(width, height) / 2).map { $0.rotated(byDegrees: rotation) + center }
    }

    /// Shortest distance from `p` to the segment `a`–`b`.
    public static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: Point(a.x + t * dx, a.y + t * dy))
    }

    /// Shortest distance from `p` to an open polyline.
    public static func distance(from p: Point, toPolyline pts: [Point]) -> Double {
        guard pts.count > 1 else { return pts.first.map { p.distance(to: $0) } ?? .infinity }
        var best = Double.infinity
        for i in 1..<pts.count { best = min(best, distance(from: p, toSegment: pts[i - 1], pts[i])) }
        return best
    }

    /// Even-odd point-in-polygon test. The polygon is implicitly closed.
    public static func contains(_ polygon: [Point], _ p: Point) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

public extension Track {
    /// The track centre line as points (two for a segment, several for an arc).
    var centerline: [Point] {
        switch kind {
        case .segment: return [start, end]
        case .arc(let mid): return Shapes.arcPoints(start: start, mid: mid, end: end)
        }
    }
}

public extension Graphic {
    /// The stroke path of this graphic as a polyline in board coordinates.
    /// Closed shapes repeat their first point at the end.
    var polyline: [Point] {
        switch kind {
        case .line, .curve:
            return points
        case .arc:
            guard points.count == 3 else { return points }
            return Shapes.arcPoints(start: points[0], mid: points[1], end: points[2])
        case .circle:
            guard points.count == 2 else { return points }
            let c = points[0], r = points[0].distance(to: points[1])
            let n = 72
            return (0...n).map { i in
                let t = 2 * Double.pi * Double(i) / Double(n)
                return Point(c.x + r * cos(t), c.y + r * sin(t))
            }
        case .rect:
            guard points.count == 2 else { return points }
            let a = points[0], b = points[1]
            return [a, Point(b.x, a.y), b, Point(a.x, b.y), a]
        case .polygon:
            guard let first = points.first else { return [] }
            return points + [first]
        }
    }
}

public extension Pad {
    /// The pad's copper outline as a polygon in board coordinates. Rounded
    /// corners and ovals are approximated with short segments.
    var outline: [Point] {
        let w = size.width, h = size.height
        var local: [Point]
        switch shape {
        case .circle:
            let r = w / 2
            local = (0..<48).map { i in
                let t = 2 * Double.pi * Double(i) / 48
                return Point(r * cos(t), r * sin(t))
            }
        case .oval:
            local = Pad.roundedRect(w: w, h: h, radius: min(w, h) / 2)
        case .roundrect:
            local = Pad.roundedRect(w: w, h: h, radius: (roundrectRatio ?? 0.25) * min(w, h))
        default:
            local = [Point(-w / 2, -h / 2), Point(w / 2, -h / 2), Point(w / 2, h / 2), Point(-w / 2, h / 2)]
        }
        return local.map { $0.rotated(byDegrees: rotation) + position }
    }

    internal static func roundedRect(w: Double, h: Double, radius: Double) -> [Point] {
        let r = max(0, min(radius, min(w, h) / 2))
        let hx = w / 2 - r, hy = h / 2 - r
        let corners = [(Point(hx, hy), 0.0), (Point(-hx, hy), 90.0), (Point(-hx, -hy), 180.0), (Point(hx, -hy), 270.0)]
        var out: [Point] = []
        for (c, startDeg) in corners {
            for k in 0...8 {
                let t = (startDeg + 90 * Double(k) / 8) * .pi / 180
                out.append(Point(c.x + r * cos(t), c.y + r * sin(t)))
            }
        }
        return out
    }
}
