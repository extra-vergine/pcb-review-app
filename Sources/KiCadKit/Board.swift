import Foundation

/// Everything the reviewer needs from a `.kicad_pcb` file, in absolute board
/// coordinates (mm, Y down).
public struct Board: Sendable {
    /// File format version, e.g. 20260206 for KiCad 10.0.
    public var version: Int
    public var generatorVersion: String?
    public var title: String?
    public var revision: String?
    public var date: String?

    public var layers: [Layer] = []
    public var stackup: [StackupLayer] = []
    /// Board thickness from `(general (thickness ..))`, mm.
    public var thickness: Double?
    /// The drill/place origin from `(setup (aux_axis_origin x y))`.
    public var auxAxisOrigin: Point?
    /// The grid origin from `(setup (grid_origin x y))`.
    public var gridOrigin: Point?

    /// The user origin used for coordinates and rulers: the drill/place
    /// origin if set, else the grid origin, else (0, 0).
    public var userOrigin: Point { auxAxisOrigin ?? gridOrigin ?? Point(0, 0) }

    /// Every net name referenced anywhere on the board, sorted. KiCad 10 files
    /// have no numbered net table: items name their net directly.
    public var nets: [String] = []

    public var footprints: [Footprint] = []
    public var tracks: [Track] = []
    public var vias: [Via] = []
    public var zones: [Zone] = []
    public var graphics: [Graphic] = []
    public var texts: [BoardText] = []

    /// Board-level `Edge.Cuts` graphics plus any `Edge.Cuts` graphics inside footprints.
    public var outline: [Graphic] {
        graphics.filter { $0.layer == "Edge.Cuts" } + footprints.flatMap { $0.graphics.filter { $0.layer == "Edge.Cuts" } }
    }

    /// Bounding box of the board outline.
    public var outlineBounds: Rect? {
        Rect.enclosing(outline.flatMap(\.points))
    }

    /// All pads of all footprints.
    public var pads: [Pad] { footprints.flatMap(\.pads) }
}

public struct Footprint: Sendable {
    public var libraryID: String
    public var reference: String
    public var value: String
    public var position: Point
    public var rotation: Double
    /// `F.Cu` or `B.Cu`.
    public var layer: String
    /// Attributes from `(attr ...)`, e.g. `smd`, `through_hole`, `exclude_from_bom`.
    public var attributes: [String]
    public var sheetName: String?
    public var properties: [String: String]
    public var pads: [Pad]
    /// Footprint graphics, already transformed to board coordinates.
    public var graphics: [Graphic]
    /// Rule areas and zones that belong to the footprint.
    public var zones: [Zone]
    public var uuid: String?

    public var isBottom: Bool { layer == "B.Cu" }
}

public struct Pad: Sendable {
    public enum Kind: String, Sendable { case smd, thruHole = "thru_hole", npThruHole = "np_thru_hole", connect }
    public enum Shape: String, Sendable { case circle, rect, oval, trapezoid, roundrect, custom, chamferedRect = "chamfered_rect" }

    public var number: String
    public var kind: Kind
    public var shape: Shape
    /// Pad centre in board coordinates.
    public var position: Point
    /// Absolute orientation in degrees (KiCad stores the footprint rotation already included).
    public var rotation: Double
    public var size: (width: Double, height: Double)
    public var drill: Drill?
    /// Layer names after wildcard expansion, e.g. all copper layers for `*.Cu`.
    public var layers: [String]
    public var net: String?
    public var roundrectRatio: Double?
    /// Owning footprint reference, e.g. `R24`.
    public var footprintReference: String
    public var uuid: String?

    public var isPlated: Bool { kind == .thruHole }
    public var copperLayers: [String] { layers.filter { $0.hasSuffix(".Cu") } }
}

public struct Drill: Equatable, Sendable {
    /// Diameter, or the width for an oval (slot) drill.
    public var diameter: Double
    /// Slot height for an oval drill; nil for a round hole.
    public var slotHeight: Double?
    public var offset: Point?

    public var isSlot: Bool { slotHeight != nil }
    /// The smallest dimension of the hole.
    public var minimumSize: Double { min(diameter, slotHeight ?? diameter) }
}

public struct Track: Sendable {
    public enum Kind: Sendable { case segment, arc(mid: Point) }
    public var kind: Kind
    public var start: Point
    public var end: Point
    public var width: Double
    public var layer: String
    public var net: String?
    public var uuid: String?

    public var isArc: Bool { if case .arc = kind { return true } else { return false } }
}

public struct Via: Sendable {
    public enum Kind: String, Sendable { case through, blind, buried, micro }
    public var kind: Kind
    public var position: Point
    public var size: Double
    public var drill: Double
    /// The two end layers as written, e.g. `F.Cu`, `B.Cu`.
    public var endLayers: [String]
    /// Every copper layer the via passes through.
    public var spannedLayers: [String]
    public var net: String?
    public var uuid: String?

    public var annularRing: Double { (size - drill) / 2 }
}

public struct Zone: Sendable {
    public var net: String?
    public var name: String?
    public var layers: [String]
    /// The outline as drawn.
    public var outline: [Point]
    /// The filled copper, per layer. Empty if the zone was never filled.
    public var filledPolygons: [(layer: String, points: [Point])]
    public var minThickness: Double?
    /// Pad clearance from `(connect_pads (clearance ..))`.
    public var clearance: Double?
    /// Set for rule areas (`keepout`).
    public var keepout: Keepout?
    public var uuid: String?

    public var isRuleArea: Bool { keepout != nil }
}

public struct Keepout: Equatable, Sendable {
    public var tracks: Bool
    public var vias: Bool
    public var pads: Bool
    public var copperPour: Bool
    public var footprints: Bool
}

public struct Graphic: Sendable {
    public enum Kind: String, Sendable { case line, arc, circle, rect, polygon, curve }
    public var kind: Kind
    /// line/rect: start, end. arc: start, mid, end. circle: center, a point on the circle.
    /// polygon/curve: the vertices or control points.
    public var points: [Point]
    public var width: Double
    public var layer: String
    public var filled: Bool
    public var uuid: String?
}

public struct BoardText: Sendable {
    public var text: String
    public var position: Point
    public var rotation: Double
    public var layer: String
    /// Font height in mm.
    public var height: Double?
    public var thickness: Double?
    public var hidden: Bool
    /// Owning footprint reference for footprint texts and fields.
    public var footprintReference: String?
}
