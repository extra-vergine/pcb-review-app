import Foundation

/// A fab's published manufacturing limits, read from a JSON data file in
/// `Sources/KiCadKit/Profiles`. Every value carries the page it came from,
/// the words on that page and the date it was checked.
public struct FabProfile: Codable, Identifiable, Sendable {
    public struct Source: Codable, Sendable {
        public var id: String
        public var title: String
        public var url: String
    }

    public struct Rule: Codable, Sendable {
        /// One of the ids in `FabProfile.RuleID`.
        public var id: String
        /// The fab's limit in mm. Below it is an error (or a warning if unverified).
        public var value: Double
        /// A safer value the fab recommends. Below it, but above `value`, is a warning.
        public var recommended: Double?
        /// The `id` of the source page.
        public var source: String
        /// The wording on the page.
        public var quote: String
        /// False when the value was not read word for word from the page.
        public var verified: Bool
    }

    /// The rule ids the checks understand.
    public enum RuleID: String, CaseIterable, Sendable {
        case minTrackWidth = "min_track_width"
        case minClearance = "min_clearance"
        case minPadToTrack = "min_pad_to_track"
        case minSMDPadToPad = "min_smd_pad_to_pad"
        case minViaDrill = "min_via_drill"
        case minViaDiameter = "min_via_diameter"
        case minViaAnnularRing = "min_via_annular_ring"
        case minPTHDrill = "min_pth_drill"
        case maxPTHDrill = "max_pth_drill"
        case minNPTHDrill = "min_npth_drill"
        case minPTHAnnularRing = "min_pth_annular_ring"
        case minViaHoleToHole = "min_via_hole_to_hole"
        case minPadHoleToHole = "min_pad_hole_to_hole"
        case minViaHoleToTrack = "min_via_hole_to_track"
        case minPTHHoleToTrack = "min_pth_hole_to_track"
        case minNPTHHoleToTrack = "min_npth_hole_to_track"
        case minCopperToEdge = "min_copper_to_edge"
        case minSilkLineWidth = "min_silk_line_width"
        case minSilkTextHeight = "min_silk_text_height"
        case minSilkToPad = "min_silk_to_pad"
        case minPlatedSlot = "min_plated_slot"
        case minNPTHSlot = "min_npth_slot"
        case minBoardThickness = "min_board_thickness"
        case maxBoardThickness = "max_board_thickness"
    }

    public var id: String
    public var name: String
    /// What kind of board the values are for.
    public var scope: String
    /// The date the values were checked against the fab's pages, `yyyy-MM-dd`.
    public var checked: String
    public var sources: [Source]
    public var notes: [String]
    public var rules: [Rule]

    public func rule(_ id: RuleID) -> Rule? { rules.first { $0.id == id.rawValue } }
    public func source(of rule: Rule) -> Source? { sources.first { $0.id == rule.source } }

    /// Rule ids in the file that no check uses (a typo, or a newer file).
    public var unknownRuleIDs: [String] { rules.map(\.id).filter { RuleID(rawValue: $0) == nil } }
}

public enum FabProfiles {
    /// The ids of the bundled profiles.
    public static let bundledIDs = ["jlcpcb", "pcbway"]

    /// All bundled profiles, in the order of `bundledIDs`.
    public static func bundled() -> [FabProfile] {
        bundledIDs.compactMap { try? load(id: $0) }
    }

    public static func load(id: String) throws -> FabProfile {
        let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "Profiles")
            ?? Bundle.module.url(forResource: id, withExtension: "json")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> FabProfile {
        try JSONDecoder().decode(FabProfile.self, from: data)
    }
}
