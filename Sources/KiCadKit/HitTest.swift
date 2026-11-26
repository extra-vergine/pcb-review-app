import Foundation

/// A reference to one item on the board, used for selection and for findings.
public enum BoardItem: Hashable, Sendable {
    case pad(footprint: Int, pad: Int)
    case footprint(Int)
    case track(Int)
    case via(Int)
    case zone(Int)
}

public extension Board {
    /// The net of an item, if it has one.
    func net(of item: BoardItem) -> String? {
        switch item {
        case .pad(let f, let p): return footprints[f].pads[p].net
        case .footprint: return nil
        case .track(let i): return tracks[i].net
        case .via(let i): return vias[i].net
        case .zone(let i): return zones[i].net
        }
    }

    /// The top-most item at `point` among `visibleLayers`, picked in the order
    /// vias, pads, tracks, footprints (by courtyard or body), zones.
    /// `tolerance` widens thin items so they are easy to click, in mm.
    func hitTest(_ point: Point, visibleLayers: Set<String>, tolerance: Double = 0.05) -> BoardItem? {
        func visible(_ layers: [String]) -> Bool { layers.contains { visibleLayers.contains($0) } }

        for (i, v) in vias.enumerated() where visible(v.spannedLayers) {
            if v.position.distance(to: point) <= v.size / 2 + tolerance { return .via(i) }
        }
        for (f, fp) in footprints.enumerated() {
            for (p, pad) in fp.pads.enumerated() where visible(pad.copperLayers) {
                if Shapes.contains(pad.outline, point) { return .pad(footprint: f, pad: p) }
            }
        }
        // Later tracks are drawn on top, so test them first.
        for (i, t) in tracks.enumerated().reversed() where visibleLayers.contains(t.layer) {
            if Shapes.distance(from: point, toPolyline: t.centerline) <= t.width / 2 + tolerance { return .track(i) }
        }
        for (f, fp) in footprints.enumerated() {
            let side = fp.isBottom ? "B" : "F"
            guard visibleLayers.contains("\(side).Cu") || visibleLayers.contains("\(side).SilkS") else { continue }
            if let box = fp.courtyardBounds, point.x >= box.minX, point.x <= box.maxX, point.y >= box.minY, point.y <= box.maxY {
                return .footprint(f)
            }
        }
        for (i, z) in zones.enumerated() where !z.isRuleArea {
            for fill in z.filledPolygons where visibleLayers.contains(fill.layer) {
                if Shapes.contains(fill.points, point) { return .zone(i) }
            }
        }
        return nil
    }
}

public extension Footprint {
    /// Bounding box of the courtyard, or of the pads if there is no courtyard.
    var courtyardBounds: Rect? {
        let crt = graphics.filter { $0.layer.hasSuffix(".CrtYd") }.flatMap(\.polyline)
        if let r = Rect.enclosing(crt) { return r }
        return Rect.enclosing(pads.flatMap(\.outline))
    }
}
