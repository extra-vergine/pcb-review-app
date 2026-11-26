import Foundation

/// Custom design rules from a `.kicad_dru` file.
public struct CustomRules: Sendable {
    public var version: Int?
    public var rules: [CustomRule]
}

public struct CustomRule: Sendable {
    public var name: String
    /// Rule condition expression as written, e.g. `A.NetName == 'VPOE'`. Nil means it applies everywhere.
    public var condition: String?
    /// Layer filter such as `outer`, `inner` or `?.Silkscreen`.
    public var layer: String?
    public var severity: String?
    public var constraints: [RuleConstraint]
}

public struct RuleConstraint: Sendable {
    /// `clearance`, `hole_size`, `annular_width`, `edge_clearance`, `track_width`, `text_height`, ...
    public var type: String
    /// Limits in mm (or degrees for angle constraints).
    public var min: Double?
    public var opt: Double?
    public var max: Double?
    /// Any other arguments, e.g. the item types of `(constraint disallow track via)`.
    public var arguments: [String]
}

public enum CustomRulesParser {
    public static func parse(contentsOf url: URL) throws -> CustomRules {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> CustomRules {
        let top = try SExprParser.parse(text, allowComments: true)
        var out = CustomRules(version: nil, rules: [])
        for node in top {
            switch node.head ?? "" {
            case "version":
                out.version = node.atom(at: 1).flatMap { Int($0) }
            case "rule":
                out.rules.append(CustomRule(
                    name: node.atom(at: 1) ?? "",
                    condition: node.text("condition"),
                    layer: node.text("layer"),
                    severity: node.text("severity"),
                    constraints: node.children("constraint").map(parseConstraint)
                ))
            default:
                break
            }
        }
        return out
    }

    static func parseConstraint(_ c: SExpr) -> RuleConstraint {
        let args = c.items.dropFirst(2)
        return RuleConstraint(
            type: c.atom(at: 1) ?? "",
            min: c.child("min")?.atom(at: 1).flatMap(Units.parseLength),
            opt: c.child("opt")?.atom(at: 1).flatMap(Units.parseLength),
            max: c.child("max")?.atom(at: 1).flatMap(Units.parseLength),
            arguments: args.compactMap(\.atom)
        )
    }
}

public enum Units {
    /// Parses `1.9mm`, `10mil`, `0.01in`, `45deg` or a bare number (mm).
    public static func parseLength(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        let table: [(String, Double)] = [("mm", 1), ("mil", 0.0254), ("in", 25.4), ("um", 0.001), ("deg", 1)]
        for (suffix, factor) in table where t.hasSuffix(suffix) {
            return Double(t.dropLast(suffix.count)).map { $0 * factor }
        }
        return Double(t)
    }
}
