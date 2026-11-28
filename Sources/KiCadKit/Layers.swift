import Foundation

/// One entry of the board's `(layers ...)` table.
public struct Layer: Equatable, Sendable {
    /// KiCad's internal layer id. In KiCad 9+ copper ids are F.Cu=0, B.Cu=2, In1.Cu=4, In2.Cu=6, ...
    public let id: Int
    /// Canonical name such as `F.Cu` or `F.SilkS`.
    public let name: String
    /// `signal`, `power`, `mixed`, `jumper` or `user`.
    public let type: String
    /// Optional display name such as `F.Silkscreen` or `GND`.
    public let userName: String?

    public var isCopper: Bool { name.hasSuffix(".Cu") }
}

/// One row of the physical stackup in `(setup (stackup ...))`.
public struct StackupLayer: Equatable, Sendable {
    public let name: String
    public let type: String
    public let thickness: Double?
    public let material: String?
    public let epsilonR: Double?
    /// Colour name as KiCad writes it, e.g. `Green`, `Black` or `#1A2B3CFF` (mask and silkscreen layers).
    public var color: String? = nil
}

public extension Board {
    /// Copper layers in physical order, top to bottom.
    var copperLayers: [Layer] {
        let cu = layers.filter(\.isCopper)
        func rank(_ l: Layer) -> Int {
            if l.name == "F.Cu" { return Int.min }
            if l.name == "B.Cu" { return Int.max }
            return Int(l.name.dropFirst(2).prefix { $0.isNumber }) ?? 0 // "In12.Cu" -> 12
        }
        return cu.sorted { rank($0) < rank($1) }
    }

    /// Expands wildcard layer names used by pads and vias, such as `*.Cu`,
    /// `F&B.Cu` and `*.Mask`, into concrete layer names present on this board.
    func expandLayers(_ names: [String]) -> [String] {
        var out: [String] = []
        func add(_ n: String) { if !out.contains(n) { out.append(n) } }
        for n in names {
            if n == "*.Cu" {
                copperLayers.forEach { add($0.name) }
            } else if n.hasPrefix("*.") {
                let suffix = String(n.dropFirst(1)) // ".Mask"
                add("F" + suffix); add("B" + suffix)
            } else if n.hasPrefix("F&B.") {
                let suffix = String(n.dropFirst(3))
                add("F" + suffix); add("B" + suffix)
            } else {
                add(n)
            }
        }
        return out
    }

    /// Copper layers spanned by a via from `top` to `bottom` (inclusive).
    func copperSpan(from top: String, to bottom: String) -> [String] {
        let names = copperLayers.map(\.name)
        guard let a = names.firstIndex(of: top), let b = names.firstIndex(of: bottom) else { return [top, bottom] }
        return Array(names[min(a, b)...max(a, b)])
    }
}
