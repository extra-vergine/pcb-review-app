import Foundation

/// A length unit for display.
public enum LengthUnit: String, CaseIterable, Sendable {
    case mm, inch = "in", point = "pt", mil

    /// Millimetres per unit.
    public var millimetres: Double {
        switch self {
        case .mm: return 1
        case .inch: return 25.4
        case .point: return 25.4 / 72
        case .mil: return 0.0254
        }
    }

    /// The next unit in the cycle mm → in → pt → mil → mm.
    public var next: LengthUnit {
        switch self {
        case .mm: return .inch
        case .inch: return .point
        case .point: return .mil
        case .mil: return .mm
        }
    }

    /// Decimal places that give about 1 µm resolution.
    public var decimals: Int {
        switch self {
        case .mm: return 3
        case .inch: return 4
        case .point: return 2
        case .mil: return 1
        }
    }

    public func value(_ millimetres: Double) -> Double { millimetres / self.millimetres }

    public func format(_ millimetres: Double, withUnit: Bool = true) -> String {
        let s = String(format: "%.\(decimals)f", value(millimetres))
        return withUnit ? "\(s) \(rawValue)" : s
    }
}

/// A linear dimension between two features, measured along X or Y.
public struct LinearDimension: Equatable, Sendable {
    public enum Axis: Sendable { case horizontal, vertical }
    public var axis: Axis
    /// The two measured features.
    public var from: Point
    public var to: Point
    /// Where the dimension line sits: a Y for horizontal dimensions, an X for vertical ones.
    public var lineAt: Double

    /// The measured length in mm.
    public var length: Double {
        axis == .horizontal ? abs(to.x - from.x) : abs(to.y - from.y)
    }
}

public extension Board {
    /// Footprints that are mounting holes: from a `MountingHole` library, or
    /// referenced `H1`, `H2`, ... with a hole of at least 2 mm.
    var mountingHoles: [Footprint] {
        footprints.filter { fp in
            if fp.libraryID.hasPrefix("MountingHole:") { return true }
            let isH = fp.reference.first == "H" && fp.reference.dropFirst().allSatisfy(\.isNumber) && fp.reference.count > 1
            return isH && fp.pads.contains { ($0.drill?.diameter ?? 0) >= 2 }
        }
    }

    /// Overall board size along one axis, with the dimension line `offset` mm outside the outline
    /// (above the board for horizontal, right of it for vertical).
    func overallDimension(_ axis: LinearDimension.Axis, offset: Double = 6) -> LinearDimension? {
        guard let b = outlineBounds else { return nil }
        switch axis {
        case .horizontal:
            return LinearDimension(axis: .horizontal, from: Point(b.minX, b.minY), to: Point(b.maxX, b.minY), lineAt: b.minY - offset)
        case .vertical:
            return LinearDimension(axis: .vertical, from: Point(b.maxX, b.minY), to: Point(b.maxX, b.maxY), lineAt: b.maxX + offset)
        }
    }

    /// Chained dimensions between the mounting holes along one axis: one
    /// dimension between each pair of neighbouring hole positions.
    /// Horizontal ones sit `offset` mm above the outline, vertical ones `offset` mm left of it.
    func mountingHoleDimensions(_ axis: LinearDimension.Axis, offset: Double = 3) -> [LinearDimension] {
        guard let b = outlineBounds else { return [] }
        let centres = mountingHoles.map(\.position)
        func key(_ p: Point) -> Double { axis == .horizontal ? p.x : p.y }
        var stops: [Point] = []
        for p in centres.sorted(by: { key($0) < key($1) }) {
            if let last = stops.last, abs(key(last) - key(p)) < 0.01 { continue }
            stops.append(p)
        }
        guard stops.count > 1 else { return [] }
        return zip(stops, stops.dropFirst()).map { a, c in
            LinearDimension(axis: axis, from: a, to: c,
                            lineAt: axis == .horizontal ? b.minY - offset : b.minX - offset)
        }
    }
}
