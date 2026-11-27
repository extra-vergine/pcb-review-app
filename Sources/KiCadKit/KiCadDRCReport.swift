import Foundation

/// Reads the JSON report written by `kicad-cli pcb drc --format json`, so
/// KiCad's own DRC can be shown next to this app's checks as a cross-check.
public enum KiCadDRCReport {
    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }

    /// The arguments for `kicad-cli` that write the report to `output`.
    public static func arguments(board: URL, output: URL) -> [String] {
        ["pcb", "drc", "--format", "json", "--severity-all", "--units", "mm", "-o", output.path, board.path]
    }

    /// Converts the report into findings on `board`. Items are matched to
    /// board items by their UUID where possible.
    public static func findings(from data: Data, board: Board) throws -> [Finding] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(description: "not a KiCad DRC report")
        }
        if let units = root["coordinate_units"] as? String, units != "mm" {
            throw ParseError(description: "the report uses \(units); run kicad-cli with --units mm")
        }
        let items = board.itemsByUUID
        let version = root["kicad_version"] as? String
        var out: [Finding] = []
        let sections: [(String, CheckKind)] = [("violations", .drcViolation), ("unconnected_items", .drcUnconnected), ("schematic_parity", .drcParity)]
        for (key, kind) in sections {
            for v in (root[key] as? [[String: Any]]) ?? [] {
                let type = v["type"] as? String ?? key
                let description = v["description"] as? String ?? type
                let severity: FindingSeverity
                switch (v["severity"] as? String ?? "error").lowercased() {
                case "error": severity = .error
                case "warning": severity = .warning
                default: severity = .info
                }
                var points: [Point] = []
                var names: [String] = []
                var found: [BoardItem] = []
                for it in (v["items"] as? [[String: Any]]) ?? [] {
                    if let pos = it["pos"] as? [String: Any], let x = number(pos["x"]), let y = number(pos["y"]) {
                        points.append(Point(x, y))
                    }
                    if let d = it["description"] as? String { names.append(d) }
                    if let u = it["uuid"] as? String, let item = items[u] { found.append(item) }
                }
                let at = points.first ?? board.outlineBounds?.center ?? Point(0, 0)
                var area = Rect.enclosing(points) ?? Rect(minX: at.x, minY: at.y, maxX: at.x, maxY: at.y)
                area = Rect(minX: area.minX - 0.5, minY: area.minY - 0.5, maxX: area.maxX + 0.5, maxY: area.maxY + 0.5)
                let message = ([description] + names).joined(separator: "\n  ")
                out.append(Finding(id: 0, suite: .kicadDRC, kind: kind, severity: severity, message: message,
                                   rule: RuleReference(title: "KiCad DRC: \(type)",
                                                       detail: version.map { "kicad-cli pcb drc, KiCad \($0)" } ?? "kicad-cli pcb drc",
                                                       url: nil, verified: true),
                                   location: at, area: area, layer: nil, items: found))
            }
        }
        return out
    }

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
}

public extension Board {
    /// Board items by their KiCad UUID.
    var itemsByUUID: [String: BoardItem] {
        var m: [String: BoardItem] = [:]
        for (i, t) in tracks.enumerated() { if let u = t.uuid { m[u] = .track(i) } }
        for (i, v) in vias.enumerated() { if let u = v.uuid { m[u] = .via(i) } }
        for (i, z) in zones.enumerated() { if let u = z.uuid { m[u] = .zone(i) } }
        for (f, fp) in footprints.enumerated() {
            if let u = fp.uuid { m[u] = .footprint(f) }
            for (p, pad) in fp.pads.enumerated() { if let u = pad.uuid { m[u] = .pad(footprint: f, pad: p) } }
        }
        return m
    }
}
