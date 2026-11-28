import Foundation

/// A colour or material a fab offers, for previewing the board.
public struct FabFinishOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: RGBA
    /// Which fabs offer it, e.g. ["JLCPCB", "PCBWay"].
    public var offeredBy: [String]

    public var label: String { "\(name) (\(offeredBy.joined(separator: ", ")))" }
}

/// Solder mask colours, base materials and copper finishes for the board preview,
/// as offered on JLCPCB's and PCBWay's order pages. These are only for the look
/// of the board; the checks do not use them.
public enum BoardAppearance {
    static let both = ["JLCPCB", "PCBWay"]

    public static let maskOptions: [FabFinishOption] = [
        .init(id: "green", name: "Green", color: RGBA(0.07, 0.36, 0.18), offeredBy: both),
        .init(id: "matte-green", name: "Matte green", color: RGBA(0.13, 0.32, 0.2), offeredBy: ["PCBWay"]),
        .init(id: "red", name: "Red", color: RGBA(0.62, 0.1, 0.1), offeredBy: both),
        .init(id: "yellow", name: "Yellow", color: RGBA(0.86, 0.72, 0.12), offeredBy: both),
        .init(id: "blue", name: "Blue", color: RGBA(0.1, 0.22, 0.55), offeredBy: both),
        .init(id: "purple", name: "Purple", color: RGBA(0.33, 0.14, 0.45), offeredBy: both),
        .init(id: "white", name: "White", color: RGBA(0.92, 0.92, 0.9), offeredBy: both),
        .init(id: "black", name: "Black", color: RGBA(0.08, 0.08, 0.09), offeredBy: both),
        .init(id: "matte-black", name: "Matte black", color: RGBA(0.12, 0.12, 0.12), offeredBy: ["PCBWay"]),
        .init(id: "none", name: "No mask", color: RGBA(0, 0, 0, 0), offeredBy: ["PCBWay"]),
    ]

    public static let materialOptions: [FabFinishOption] = [
        .init(id: "fr4", name: "FR-4", color: RGBA(0.75, 0.7, 0.48), offeredBy: both),
        .init(id: "aluminium", name: "Aluminium core", color: RGBA(0.78, 0.79, 0.8), offeredBy: both),
        .init(id: "copper-core", name: "Copper core", color: RGBA(0.78, 0.48, 0.3), offeredBy: both),
        .init(id: "rogers", name: "Rogers (RF laminate)", color: RGBA(0.86, 0.82, 0.72), offeredBy: both),
        .init(id: "flex", name: "Flex (polyimide)", color: RGBA(0.85, 0.55, 0.12), offeredBy: both),
    ]

    /// Copper finish colours by KiCad's `copper_finish` names.
    public static func finishColor(_ finish: String?) -> RGBA {
        let f = (finish ?? "").lowercased()
        if f.contains("enig") || f.contains("gold") { return RGBA(0.86, 0.7, 0.36) }
        if f.contains("osp") || f.contains("none") { return RGBA(0.8, 0.5, 0.32) }
        return RGBA(0.78, 0.79, 0.8) // HASL, immersion silver/tin
    }

    /// A colour name as KiCad writes it in the stackup: a name such as `Green`, or `#RRGGBB[AA]`.
    public static func kicadColor(_ name: String?) -> RGBA? {
        guard let name, !name.isEmpty else { return nil }
        if name.hasPrefix("#") {
            let hex = name.dropFirst()
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let n = hex.count == 8 ? v >> 8 : v
            let a = hex.count == 8 ? Double(v & 0xFF) / 255 : 1
            return RGBA(Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255, a)
        }
        let key = name.lowercased()
        let table: [String: RGBA] = [
            "green": RGBA(0.07, 0.36, 0.18), "light green": RGBA(0.36, 0.62, 0.3), "saturated green": RGBA(0.0, 0.5, 0.15),
            "red": RGBA(0.62, 0.1, 0.1), "light red": RGBA(0.82, 0.3, 0.3), "red/orange": RGBA(0.8, 0.3, 0.1),
            "blue": RGBA(0.1, 0.22, 0.55), "light blue": RGBA(0.3, 0.5, 0.85), "purple": RGBA(0.33, 0.14, 0.45),
            "yellow": RGBA(0.86, 0.72, 0.12), "white": RGBA(0.92, 0.92, 0.9), "black": RGBA(0.08, 0.08, 0.09),
            "grey": RGBA(0.5, 0.5, 0.5), "dark grey": RGBA(0.3, 0.3, 0.3), "light grey": RGBA(0.75, 0.75, 0.75),
            "not specified": RGBA(0.07, 0.36, 0.18),
        ]
        return table[key]
    }

    /// The colour of an FR-4 style core, from its material name.
    public static func materialColor(_ material: String?) -> RGBA {
        let m = (material ?? "fr4").lowercased()
        if m.contains("alu") { return materialOptions[1].color }
        if m.contains("polyimide") || m.contains("kapton") { return materialOptions[4].color }
        if m.contains("rogers") || m.contains("ro4") { return materialOptions[3].color }
        return materialOptions[0].color
    }
}

public extension Board {
    /// The top solder mask colour from the stackup, if the file sets one.
    var fileMaskColor: RGBA? {
        BoardAppearance.kicadColor(stackup.first { $0.name == "F.Mask" }?.color)
    }
    var fileSilkColor: RGBA? {
        BoardAppearance.kicadColor(stackup.first { $0.name == "F.SilkS" }?.color)
    }
    /// The core material from the stackup, e.g. `FR4`.
    var fileCoreMaterial: String? {
        stackup.first { $0.type == "core" }?.material
    }
}
