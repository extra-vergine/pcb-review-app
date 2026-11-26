import Foundation

/// A point in board coordinates: millimetres, X to the right, Y down (KiCad's convention).
public struct Point: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }

    public func distance(to p: Point) -> Double { hypot(x - p.x, y - p.y) }

    /// Rotates by `degrees` the way KiCad does: positive angles turn
    /// counter-clockwise on screen, with Y pointing down.
    public func rotated(byDegrees degrees: Double) -> Point {
        guard degrees != 0 else { return self }
        let t = degrees * .pi / 180
        let c = cos(t), s = sin(t)
        return Point(x * c + y * s, -x * s + y * c)
    }

    public var description: String { "(\(x), \(y))" }
}

public struct Rect: Equatable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    public static func enclosing<S: Sequence>(_ points: S) -> Rect? where S.Element == Point {
        var it = points.makeIterator()
        guard let first = it.next() else { return nil }
        var r = Rect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        while let p = it.next() {
            r.minX = min(r.minX, p.x); r.maxX = max(r.maxX, p.x)
            r.minY = min(r.minY, p.y); r.maxY = max(r.maxY, p.y)
        }
        return r
    }
}

extension SExpr {
    /// Reads `(at x y [angle])`, `(start x y)`, `(xy x y)` and similar.
    var point: Point? {
        guard let x = double(at: 1), let y = double(at: 2) else { return nil }
        return Point(x, y)
    }

    func point(_ name: String) -> Point? { child(name)?.point }

    /// Reads `(pts (xy ..) (xy ..))` into points. Arc segments inside `pts`
    /// (`(arc (start) (mid) (end))`) contribute their three points.
    var polyline: [Point] {
        guard let pts = child("pts") else { return [] }
        var out: [Point] = []
        for item in pts.items.dropFirst() {
            switch item.head ?? "" {
            case "xy": if let p = item.point { out.append(p) }
            case "arc":
                for k in ["start", "mid", "end"] { if let p = item.point(k) { out.append(p) } }
            default: break
            }
        }
        return out
    }
}
