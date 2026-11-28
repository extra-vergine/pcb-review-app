import AppKit
import SwiftUI
import KiCadKit

/// A layer as shown in the layer panel.
struct LayerInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let displayName: String
    let color: Color
    let isCopper: Bool
    let visibleByDefault: Bool
}

/// Paths drawn with one stroke width.
struct StrokeGroup {
    let width: Double
    let path: Path
}

/// Everything on one layer, prebuilt as paths in board coordinates (mm).
struct LayerPaths {
    var zoneFills = Path()
    var tracks: [StrokeGroup] = []
    var pads = Path()
    var graphics: [StrokeGroup] = []
    var filledGraphics = Path()
    /// Footprint graphics (silkscreen, fab, courtyard), hidden with the components.
    var componentGraphics: [StrokeGroup] = []
    var componentFilled = Path()
}

/// A component drawn as a body: the footprint's fabrication outline (or courtyard,
/// or pads) as a rectangle aligned with the footprint, plus its reference.
struct ComponentBody {
    let reference: String
    let isBottom: Bool
    /// Four corners in board coordinates.
    let corners: [Point]
    let center: Point
    /// Body size along the footprint's own axes, mm.
    let width: Double
    let height: Double

    init?(_ fp: Footprint) {
        let side = fp.isBottom ? "B" : "F"
        let toLocal = { (p: Point) in (p - fp.position).rotated(byDegrees: -fp.rotation) }
        var pts = fp.graphics.filter { $0.layer == "\(side).Fab" }.flatMap(\.polyline)
        if pts.isEmpty { pts = fp.graphics.filter { $0.layer == "\(side).CrtYd" }.flatMap(\.polyline) }
        if pts.isEmpty { pts = fp.pads.flatMap(\.outline) }
        guard let r = Rect.enclosing(pts.map(toLocal)), r.width > 0.05, r.height > 0.05 else { return nil }
        reference = fp.reference
        isBottom = fp.isBottom
        corners = [Point(r.minX, r.minY), Point(r.maxX, r.minY), Point(r.maxX, r.maxY), Point(r.minX, r.maxY)]
            .map { $0.rotated(byDegrees: fp.rotation) + fp.position }
        center = Point((r.minX + r.maxX) / 2, (r.minY + r.maxY) / 2).rotated(byDegrees: fp.rotation) + fp.position
        width = r.width
        height = r.height
    }
}

/// Precomputed drawing data for a board. Building paths once keeps panning and zooming smooth.
struct BoardScene {
    let layers: [LayerInfo]
    /// Drawing order, bottom-most first.
    let drawOrder: [String]
    let paths: [String: LayerPaths]
    let viaPaths: Path
    let holes: Path
    /// Pad holes only, drawn when components are shown.
    let padHoles: Path
    let bounds: Rect
    /// The board shape (outline polygon, or the bounds if the outline does not close).
    let substrate: Path
    /// Component bodies, for the Components option.
    let bodies: [ComponentBody]
    let frontBodies: Path
    let backBodies: Path

    init(board: Board) {
        var paths: [String: LayerPaths] = [:]

        func polygon(_ pts: [Point], into path: inout Path) {
            guard let first = pts.first else { return }
            path.move(to: first.cg)
            for p in pts.dropFirst() { path.addLine(to: p.cg) }
            path.closeSubpath()
        }
        func polyline(_ pts: [Point], into path: inout Path) {
            guard let first = pts.first else { return }
            path.move(to: first.cg)
            for p in pts.dropFirst() { path.addLine(to: p.cg) }
        }
        func circle(_ c: Point, _ r: Double, into path: inout Path) {
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }

        // Zone fills.
        for zone in board.zones where !zone.isRuleArea {
            for fill in zone.filledPolygons {
                polygon(fill.points, into: &paths[fill.layer, default: LayerPaths()].zoneFills)
            }
        }

        // Tracks, grouped by layer and width.
        var trackGroups: [String: [Double: Path]] = [:]
        for t in board.tracks {
            polyline(t.centerline, into: &trackGroups[t.layer, default: [:]][t.width, default: Path()])
        }
        for (layer, groups) in trackGroups {
            paths[layer, default: LayerPaths()].tracks = groups.map { StrokeGroup(width: $0.key, path: $0.value) }
        }

        // Pads, on each copper layer they occupy.
        var holes = Path()   // via holes
        var padHoles = Path()
        for pad in board.pads {
            let outline = pad.outline
            for layer in pad.copperLayers {
                polygon(outline, into: &paths[layer, default: LayerPaths()].pads)
            }
            if let d = pad.drill {
                let c = pad.position + (d.offset?.rotated(byDegrees: pad.rotation) ?? Point(0, 0))
                if let h = d.slotHeight {
                    polygon(Shapes.oval(center: c, width: d.diameter, height: h, rotation: pad.rotation), into: &padHoles)
                } else {
                    circle(c, d.diameter / 2, into: &padHoles)
                }
            }
        }

        // Vias.
        var viaPaths = Path()
        for v in board.vias {
            circle(v.position, v.size / 2, into: &viaPaths)
            circle(v.position, v.drill / 2, into: &holes)
        }

        // Board and footprint graphics.
        // Footprint outline pieces on Edge.Cuts count as board graphics, so the outline never disappears.
        var graphicGroups: [String: [Double: Path]] = [:]
        var componentGroups: [String: [Double: Path]] = [:]
        let footprintGraphics = board.footprints.flatMap(\.graphics)
        let boardGraphics = board.graphics + footprintGraphics.filter { $0.layer == "Edge.Cuts" }
        for (list, isComponent) in [(boardGraphics, false), (footprintGraphics.filter { $0.layer != "Edge.Cuts" }, true)] {
            for g in list {
                if g.filled, g.kind == .polygon || g.kind == .rect || g.kind == .circle {
                    if isComponent {
                        polygon(g.polyline, into: &paths[g.layer, default: LayerPaths()].componentFilled)
                    } else {
                        polygon(g.polyline, into: &paths[g.layer, default: LayerPaths()].filledGraphics)
                    }
                }
                let w = max(g.width, 0.01)
                if isComponent {
                    polyline(g.polyline, into: &componentGroups[g.layer, default: [:]][w, default: Path()])
                } else {
                    polyline(g.polyline, into: &graphicGroups[g.layer, default: [:]][w, default: Path()])
                }
            }
        }
        // Texts: board texts with the board graphics, footprint texts (R1, C1, …) with the components.
        for t in board.texts where !t.hidden {
            let outline = TextOutlines.path(for: t)
            guard !outline.isEmpty else { continue }
            if t.footprintReference != nil {
                paths[t.layer, default: LayerPaths()].componentFilled.addPath(outline)
            } else {
                paths[t.layer, default: LayerPaths()].filledGraphics.addPath(outline)
            }
        }
        for (layer, groups) in graphicGroups {
            paths[layer, default: LayerPaths()].graphics = groups.map { StrokeGroup(width: $0.key, path: $0.value) }
        }
        for (layer, groups) in componentGroups {
            paths[layer, default: LayerPaths()].componentGraphics = groups.map { StrokeGroup(width: $0.key, path: $0.value) }
        }

        // Layer list: only layers that have something to draw.
        let copperNames = board.copperLayers.map(\.name)
        var infos: [LayerInfo] = []
        for (i, l) in board.copperLayers.enumerated() {
            infos.append(LayerInfo(name: l.name, displayName: l.userName.map { "\(l.name) · \($0)" } ?? l.name,
                                   color: LayerColors.copper(l.name, index: i, count: copperNames.count),
                                   isCopper: true, visibleByDefault: true))
        }
        let technical = ["F.SilkS", "B.SilkS", "Edge.Cuts", "F.Mask", "B.Mask", "F.Paste", "B.Paste",
                         "F.Fab", "B.Fab", "F.CrtYd", "B.CrtYd", "Dwgs.User", "Cmts.User", "User.1"]
        let defaultOn: Set<String> = ["F.SilkS", "B.SilkS", "Edge.Cuts"]
        for name in technical + paths.keys.sorted() where !copperNames.contains(name) && !infos.contains(where: { $0.name == name }) {
            guard paths[name] != nil || name == "Dwgs.User" else { continue } // dimensions are drawn here
            let layer = board.layers.first { $0.name == name }
            let display = layer?.userName.map { "\($0)" } ?? name
            infos.append(LayerInfo(name: name, displayName: display, color: LayerColors.technical(name),
                                   isCopper: false, visibleByDefault: defaultOn.contains(name)))
        }

        self.layers = infos
        // Bottom copper first so the top layer draws over it, then technical layers.
        let copperOrder: [String] = Array(copperNames.reversed())
        let technicalOrder: [String] = Array(infos.filter { !$0.isCopper }.map(\.name).reversed())
        self.drawOrder = copperOrder + technicalOrder
        self.paths = paths
        self.viaPaths = viaPaths
        self.holes = holes
        self.padHoles = padHoles
        self.bounds = board.outlineBounds
            ?? Rect.enclosing(board.pads.map(\.position) + board.tracks.flatMap { [$0.start, $0.end] })
            ?? Rect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        var substrate = Path()
        if let outline = board.outlinePolygon {
            polygon(outline, into: &substrate)
        } else if let b = board.outlineBounds {
            substrate.addRect(CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height))
        }
        self.substrate = substrate

        let bodies = board.footprints.compactMap(ComponentBody.init)
        var front = Path(), back = Path()
        for b in bodies {
            if b.isBottom { polygon(b.corners, into: &back) } else { polygon(b.corners, into: &front) }
        }
        self.bodies = bodies
        self.frontBodies = front
        self.backBodies = back
    }

    func color(of layer: String) -> Color {
        layers.first { $0.name == layer }?.color ?? .gray
    }
}

/// Everything on one net, plus the outline of the selected item, as paths.
struct NetHighlight {
    let net: String?
    let netPaths: [String: LayerPaths]
    let viaPaths: Path
    let selectedOutline: Path

    init(net: String?, item: BoardItem, board: Board, scene: BoardScene) {
        self.net = net
        var paths: [String: LayerPaths] = [:]
        var vias = Path()
        if let net {
            var groups: [String: [Double: Path]] = [:]
            for t in board.tracks where t.net == net {
                var p = groups[t.layer, default: [:]][t.width, default: Path()]
                p.addLines(t.centerline.map(\.cg))
                groups[t.layer, default: [:]][t.width] = p
            }
            for (layer, g) in groups {
                paths[layer, default: LayerPaths()].tracks = g.map { StrokeGroup(width: $0.key, path: $0.value) }
            }
            for pad in board.pads where pad.net == net {
                for layer in pad.copperLayers {
                    paths[layer, default: LayerPaths()].pads.addLines(pad.outline.map(\.cg))
                    paths[layer, default: LayerPaths()].pads.closeSubpath()
                }
            }
            for v in board.vias where v.net == net {
                vias.addEllipse(in: CGRect(x: v.position.x - v.size / 2, y: v.position.y - v.size / 2, width: v.size, height: v.size))
            }
        }
        self.netPaths = paths
        self.viaPaths = vias

        var outline = Path()
        switch item {
        case .pad(let f, let p):
            outline.addLines(board.footprints[f].pads[p].outline.map(\.cg)); outline.closeSubpath()
        case .footprint(let f):
            if let b = board.footprints[f].courtyardBounds {
                outline.addRect(CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height))
            }
        case .track(let i):
            outline.addLines(board.tracks[i].centerline.map(\.cg))
        case .via(let i):
            let v = board.vias[i]
            outline.addEllipse(in: CGRect(x: v.position.x - v.size / 2, y: v.position.y - v.size / 2, width: v.size, height: v.size))
        case .zone(let i):
            outline.addLines(board.zones[i].outline.map(\.cg)); outline.closeSubpath()
        }
        self.selectedOutline = outline
    }
}

enum LayerColors {
    static func copper(_ name: String, index: Int, count: Int) -> Color {
        switch name {
        case "F.Cu": return Color(red: 0.85, green: 0.27, blue: 0.25)
        case "B.Cu": return Color(red: 0.30, green: 0.48, blue: 0.90)
        default:
            let inner: [Color] = [
                Color(red: 0.86, green: 0.72, blue: 0.25),
                Color(red: 0.35, green: 0.74, blue: 0.45),
                Color(red: 0.75, green: 0.42, blue: 0.82),
                Color(red: 0.30, green: 0.75, blue: 0.78),
            ]
            return inner[(index - 1 + inner.count) % inner.count]
        }
    }

    static func technical(_ name: String) -> Color {
        switch name {
        case "F.SilkS": return Color(red: 0.94, green: 0.94, blue: 0.94)
        case "B.SilkS": return Color(red: 0.80, green: 0.72, blue: 0.95)
        case "Edge.Cuts": return Color(red: 0.95, green: 0.85, blue: 0.30)
        case "F.Mask", "B.Mask": return Color(red: 0.55, green: 0.35, blue: 0.60)
        case "F.Paste", "B.Paste": return Color(red: 0.60, green: 0.60, blue: 0.65)
        case "F.CrtYd", "B.CrtYd": return Color(red: 0.85, green: 0.85, blue: 0.85).opacity(0.7)
        case "F.Fab", "B.Fab": return Color(red: 0.62, green: 0.62, blue: 0.55)
        default: return Color(red: 0.60, green: 0.65, blue: 0.70)
        }
    }
}

extension Point {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

extension CGPoint {
    var board: Point { Point(Double(x), Double(y)) }
}

extension Color {
    /// sRGB components, for saving and for the vector exports.
    var rgba: RGBA {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        return RGBA(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
