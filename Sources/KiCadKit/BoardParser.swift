import Foundation

public enum BoardParseError: Error, CustomStringConvertible {
    case notABoard
    case syntax(SExprParseError)

    public var description: String {
        switch self {
        case .notABoard: return "not a KiCad board file (expected (kicad_pcb ...))"
        case .syntax(let e): return "syntax error at \(e)"
        }
    }
}

public enum BoardParser {
    /// Oldest format this reader is written against (KiCad 10.0).
    public static let kicad10Version = 20250000

    public static func parse(contentsOf url: URL) throws -> Board {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> Board {
        let top: [SExpr]
        do { top = try SExprParser.parse(text) } catch let e as SExprParseError { throw BoardParseError.syntax(e) }
        guard let root = top.first, root.head == "kicad_pcb" else { throw BoardParseError.notABoard }

        var board = Board(version: Int(root.text("version") ?? "") ?? 0)
        board.generatorVersion = root.text("generator_version")
        if let tb = root.child("title_block") {
            board.title = tb.text("title")
            board.revision = tb.text("rev")
            board.date = tb.text("date")
            board.company = tb.text("company")
            for c in tb.children("comment") {
                if let n = c.atom(at: 1).flatMap(Int.init), let v = c.atom(at: 2) { board.comments[n] = v }
            }
        }
        board.thickness = root.child("general")?.value("thickness")
        board.layers = parseLayers(root.child("layers"))
        board.stackup = parseStackup(root.child("setup")?.child("stackup"))
        board.copperFinish = root.child("setup")?.child("stackup")?.text("copper_finish")
        board.auxAxisOrigin = root.child("setup")?.point("aux_axis_origin")
        board.gridOrigin = root.child("setup")?.point("grid_origin")

        for item in root.items.dropFirst() {
            switch item.head ?? "" {
            case "footprint", "module":
                board.footprints.append(parseFootprint(item, board: board))
                board.texts.append(contentsOf: footprintTexts(item, variables: textVariables(board)))
            case "segment":
                if let t = parseTrack(item, arc: false) { board.tracks.append(t) }
            case "arc":
                if let t = parseTrack(item, arc: true) { board.tracks.append(t) }
            case "via":
                if let v = parseVia(item, board: board) { board.vias.append(v) }
            case "zone":
                board.zones.append(parseZone(item))
            case "gr_line", "gr_arc", "gr_circle", "gr_rect", "gr_poly", "gr_curve":
                if let g = parseGraphic(item, transform: { $0 }) { board.graphics.append(g) }
            case "gr_text":
                if var t = parseText(item, transform: { $0 }, baseRotation: 0, reference: nil) {
                    t.text = expandVariables(t.text, textVariables(board))
                    board.texts.append(t)
                }
            default:
                break
            }
        }
        for fp in board.footprints {
            board.zones.append(contentsOf: fp.zones)
        }
        board.nets = collectNets(root)
        return board
    }

    // MARK: - Sections

    static func parseLayers(_ node: SExpr?) -> [Layer] {
        guard let node else { return [] }
        return node.items.dropFirst().compactMap { l in
            guard let id = l.items.first?.atom.flatMap(Int.init), let name = l.atom(at: 1) else { return nil }
            return Layer(id: id, name: name, type: l.atom(at: 2) ?? "", userName: l.atom(at: 3))
        }
    }

    static func parseStackup(_ node: SExpr?) -> [StackupLayer] {
        guard let node else { return [] }
        return node.children("layer").compactMap { l in
            guard let name = l.atom(at: 1) else { return nil }
            return StackupLayer(name: name, type: l.text("type") ?? "", thickness: l.value("thickness"),
                                material: l.text("material"), epsilonR: l.value("epsilon_r"), color: l.text("color"))
        }
    }

    /// Net names are the last argument of `(net ...)`: `(net "GND")` in KiCad 10,
    /// `(net 3 "GND")` in older files.
    static func netName(_ node: SExpr) -> String? {
        guard let n = node.child("net")?.arguments.last, !n.isEmpty else { return nil }
        return n
    }

    static func collectNets(_ root: SExpr) -> [String] {
        var names = Set<String>()
        func walk(_ n: SExpr) {
            guard case .list(let l) = n else { return }
            if n.head == "net", let name = n.arguments.last, !name.isEmpty { names.insert(name) }
            l.forEach(walk)
        }
        walk(root)
        return names.sorted()
    }

    // MARK: - Footprints

    static func parseFootprint(_ node: SExpr, board: Board) -> Footprint {
        let at = node.child("at")
        let origin = at?.point ?? Point(0, 0)
        let rotation = at?.double(at: 3) ?? 0
        let toBoard: (Point) -> Point = { $0.rotated(byDegrees: rotation) + origin }

        var props: [String: String] = [:]
        for p in node.children("property") {
            if let k = p.atom(at: 1) { props[k] = p.atom(at: 2) ?? "" }
        }
        // Older files keep reference and value in fp_text.
        for t in node.children("fp_text") {
            guard let kind = t.atom(at: 1), let v = t.atom(at: 2) else { continue }
            let key: String? = kind == "reference" ? "Reference" : kind == "value" ? "Value" : nil
            if let key, props[key] == nil { props[key] = v }
        }
        let reference = props["Reference"] ?? "?"

        var pads: [Pad] = []
        var graphics: [Graphic] = []
        var zones: [Zone] = []
        for item in node.items.dropFirst() {
            switch item.head ?? "" {
            case "pad":
                if let p = parsePad(item, toBoard: toBoard, reference: reference, board: board) { pads.append(p) }
            case "fp_line", "fp_arc", "fp_circle", "fp_rect", "fp_poly", "fp_curve":
                if let g = parseGraphic(item, transform: toBoard) { graphics.append(g) }
            case "zone":
                // Footprint zones are stored in board coordinates already.
                zones.append(parseZone(item))
            default:
                break
            }
        }

        let models: [FootprintModel] = node.children("model").compactMap { m in
            guard let path = m.atom(at: 1) else { return nil }
            func xyz(_ name: String, _ d: Double) -> (x: Double, y: Double, z: Double) {
                let n = m.child(name)?.child("xyz")
                return (n?.double(at: 1) ?? d, n?.double(at: 2) ?? d, n?.double(at: 3) ?? d)
            }
            let hidden = m.items.contains { $0.atom == "hide" } || m.child("hide")?.atom(at: 1) == "yes"
                || m.child("show")?.atom(at: 1) == "no"
            return FootprintModel(path: path, offset: xyz("offset", 0), scale: xyz("scale", 1), rotation: xyz("rotate", 0), hidden: hidden)
        }

        var footprint = Footprint(
            libraryID: node.atom(at: 1) ?? "",
            reference: reference,
            value: props["Value"] ?? "",
            position: origin,
            rotation: rotation,
            layer: node.text("layer") ?? "F.Cu",
            attributes: node.child("attr")?.arguments ?? [],
            sheetName: node.text("sheetname"),
            properties: props,
            pads: pads,
            graphics: graphics,
            zones: zones,
            uuid: node.text("uuid") ?? node.text("tstamp")
        )
        footprint.models = models
        return footprint
    }

    /// Texts (fields and `fp_text`) of a footprint, in board coordinates.
    /// The title block's text variables, e.g. `TITLE` and `COMMENT1`.
    static func textVariables(_ board: Board) -> [String: String] {
        var v: [String: String] = [:]
        v["TITLE"] = board.title
        v["REVISION"] = board.revision
        v["ISSUE_DATE"] = board.date
        v["COMPANY"] = board.company
        for (n, c) in board.comments { v["COMMENT\(n)"] = c }
        return v
    }

    /// Replaces `${NAME}` with its value; unknown names are left as they are.
    public static func expandVariables(_ text: String, _ variables: [String: String]) -> String {
        guard text.contains("${") else { return text }
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else { out += rest[start.lowerBound...]; return out }
            let name = String(rest[start.upperBound..<end])
            out += variables[name] ?? variables[name.uppercased()] ?? "${\(name)}"
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    static func footprintTexts(_ node: SExpr, variables: [String: String] = [:]) -> [BoardText] {
        let at = node.child("at")
        let origin = at?.point ?? Point(0, 0)
        let rotation = at?.double(at: 3) ?? 0
        let toBoard: (Point) -> Point = { $0.rotated(byDegrees: rotation) + origin }
        var ref: String?
        for p in node.children("property") where p.atom(at: 1) == "Reference" { ref = p.atom(at: 2) }
        var vars = variables
        for p in node.children("property") {
            if let k = p.atom(at: 1), let v = p.atom(at: 2) { vars[k.uppercased()] = v }
        }
        if let name = node.atom(at: 1) { vars["FOOTPRINT_NAME"] = String(name.split(separator: ":").last ?? "") }
        var out: [BoardText] = []
        for p in node.children("property") {
            if var t = parseText(p, transform: toBoard, baseRotation: 0, reference: ref, textIndex: 2) {
                t.text = expandVariables(t.text, vars)
                out.append(t)
            }
        }
        for t in node.children("fp_text") {
            if var x = parseText(t, transform: toBoard, baseRotation: 0, reference: ref, textIndex: 2) {
                x.text = expandVariables(x.text, vars)
                out.append(x)
            }
        }
        return out
    }

    static func parsePad(_ node: SExpr, toBoard: (Point) -> Point, reference: String, board: Board) -> Pad? {
        guard let kindRaw = node.atom(at: 2), let kind = Pad.Kind(rawValue: kindRaw),
              let shapeRaw = node.atom(at: 3), let at = node.child("at"), let local = at.point else { return nil }
        let size = node.child("size")
        var drill: Drill?
        if let d = node.child("drill") {
            let args = d.items.dropFirst()
            let isOval = args.first?.atom == "oval"
            let numbers = args.compactMap { $0.atom.flatMap(Double.init) }
            if let w = numbers.first {
                drill = Drill(diameter: w,
                              slotHeight: isOval ? numbers.dropFirst().first : nil,
                              offset: d.child("offset")?.point)
            }
        }
        return Pad(
            number: node.atom(at: 1) ?? "",
            kind: kind,
            shape: Pad.Shape(rawValue: shapeRaw) ?? .custom,
            position: toBoard(local),
            rotation: at.double(at: 3) ?? 0,
            size: (size?.double(at: 1) ?? 0, size?.double(at: 2) ?? 0),
            drill: drill,
            layers: board.expandLayers(node.child("layers")?.arguments ?? []),
            net: netName(node),
            roundrectRatio: node.value("roundrect_rratio"),
            footprintReference: reference,
            uuid: node.text("uuid") ?? node.text("tstamp")
        )
    }

    // MARK: - Copper

    static func parseTrack(_ node: SExpr, arc: Bool) -> Track? {
        guard let start = node.point("start"), let end = node.point("end"),
              let width = node.value("width"), let layer = node.text("layer") else { return nil }
        let kind: Track.Kind
        if arc {
            guard let mid = node.point("mid") else { return nil }
            kind = .arc(mid: mid)
        } else {
            kind = .segment
        }
        return Track(kind: kind, start: start, end: end, width: width, layer: layer,
                     net: netName(node), uuid: node.text("uuid") ?? node.text("tstamp"))
    }

    static func parseVia(_ node: SExpr, board: Board) -> Via? {
        guard let at = node.point("at"), let size = node.value("size"), let drill = node.value("drill") else { return nil }
        var kind = Via.Kind.through
        if case .symbol(let s)? = node.items.dropFirst().first {
            kind = Via.Kind(rawValue: s) ?? .through
        }
        let ends = node.child("layers")?.arguments ?? ["F.Cu", "B.Cu"]
        let span = ends.count == 2 ? board.copperSpan(from: ends[0], to: ends[1]) : ends
        if kind == .through, span.count < board.copperLayers.count, board.copperLayers.count > 2 {
            kind = .blind
        }
        return Via(kind: kind, position: at, size: size, drill: drill, endLayers: ends, spannedLayers: span,
                   net: netName(node), uuid: node.text("uuid") ?? node.text("tstamp"))
    }

    static func parseZone(_ node: SExpr) -> Zone {
        var layers: [String] = []
        if let l = node.text("layer") { layers = [l] }
        if let ls = node.child("layers") { layers = ls.arguments }
        var keepout: Keepout?
        if let k = node.child("keepout") {
            func forbidden(_ n: String) -> Bool { k.text(n) == "not_allowed" }
            keepout = Keepout(tracks: forbidden("tracks"), vias: forbidden("vias"), pads: forbidden("pads"),
                              copperPour: forbidden("copperpour"), footprints: forbidden("footprints"))
        }
        let filled = node.children("filled_polygon").map { fp in
            (layer: fp.text("layer") ?? layers.first ?? "", points: fp.polyline)
        }
        return Zone(net: netName(node), name: node.text("name"), layers: layers,
                    outline: node.child("polygon")?.polyline ?? [],
                    filledPolygons: filled,
                    minThickness: node.value("min_thickness"),
                    clearance: node.child("connect_pads")?.value("clearance"),
                    keepout: keepout,
                    uuid: node.text("uuid") ?? node.text("tstamp"))
    }

    // MARK: - Graphics and text

    static func parseGraphic(_ node: SExpr, transform: (Point) -> Point) -> Graphic? {
        guard let head = node.head, let layer = node.text("layer") else { return nil }
        let kind: Graphic.Kind
        var pts: [Point]
        switch head.dropFirst(3) { // "gr_" or "fp_"
        case "line":
            guard let s = node.point("start"), let e = node.point("end") else { return nil }
            kind = .line; pts = [s, e]
        case "rect":
            guard let s = node.point("start"), let e = node.point("end") else { return nil }
            kind = .rect; pts = [s, e]
        case "arc":
            guard let s = node.point("start"), let m = node.point("mid"), let e = node.point("end") else { return nil }
            kind = .arc; pts = [s, m, e]
        case "circle":
            guard let c = node.point("center"), let e = node.point("end") else { return nil }
            kind = .circle; pts = [c, e]
        case "poly":
            kind = .polygon; pts = node.polyline
        case "curve":
            kind = .curve; pts = node.polyline
        default:
            return nil
        }
        pts = pts.map(transform)
        let width = node.child("stroke")?.value("width") ?? node.value("width") ?? 0
        let fillValue = node.text("fill")
        return Graphic(kind: kind, points: pts, width: width, layer: layer,
                       filled: fillValue == "yes" || fillValue == "solid",
                       uuid: node.text("uuid") ?? node.text("tstamp"))
    }

    static func parseText(_ node: SExpr, transform: (Point) -> Point, baseRotation: Double,
                          reference: String?, textIndex: Int = 1) -> BoardText? {
        guard let at = node.child("at"), let local = at.point, let layer = node.text("layer") else { return nil }
        let text = node.atom(at: textIndex) ?? ""
        let font = node.child("effects")?.child("font")
        let effects = node.child("effects")
        let hidden = node.flag("hide") || node.text("hide") == "yes" || (effects?.flag("hide") ?? false) || effects?.text("hide") == "yes"
        var t = BoardText(text: text, position: transform(local), rotation: (at.double(at: 3) ?? 0) + baseRotation,
                          layer: layer, height: font?.child("size")?.double(at: 1),
                          thickness: font?.value("thickness"), hidden: hidden, footprintReference: reference)
        t.width = font?.child("size")?.double(at: 2)
        t.face = font?.text("face")
        t.bold = (font?.flag("bold") ?? false) || font?.text("bold") == "yes"
        t.italic = (font?.flag("italic") ?? false) || font?.text("italic") == "yes"
        let justify = effects?.child("justify")?.arguments ?? []
        t.justifyH = justify.contains("left") ? -1 : justify.contains("right") ? 1 : 0
        t.justifyV = justify.contains("top") ? -1 : justify.contains("bottom") ? 1 : 0
        t.mirrored = justify.contains("mirror")
        for poly in node.child("render_cache")?.children("polygon") ?? [] {
            for pts in poly.children("pts") {
                let points = pts.children("xy").compactMap { xy -> Point? in
                    guard let x = xy.double(at: 1), let y = xy.double(at: 2) else { return nil }
                    return Point(x, y)
                }
                if points.count >= 3 { t.renderCache.append(points) }
            }
        }
        return t
    }
}
