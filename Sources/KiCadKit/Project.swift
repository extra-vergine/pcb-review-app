import Foundation

/// Settings from a `.kicad_pro` file that matter for review: board design
/// rules and net classes. All lengths are mm.
public struct Project: Sendable {
    /// `board.design_settings.rules`, e.g. `min_clearance`, `min_track_width`.
    public var rules: [String: Double]
    public var netClasses: [NetClass]
    /// Pattern → net class, from `net_settings.netclass_patterns`.
    public var netClassPatterns: [(pattern: String, netClass: String)]
    /// Explicit net → net class assignments, from `net_settings.netclass_assignments`.
    public var netClassAssignments: [String: [String]]

    public func netClass(named name: String) -> NetClass? { netClasses.first { $0.name == name } }
    public var defaultNetClass: NetClass? { netClass(named: "Default") }

    public func rule(_ key: String) -> Double? { rules[key] }
}

public struct NetClass: Equatable, Sendable {
    public var name: String
    /// Lower number wins when several classes apply. `Default` has the largest value.
    public var priority: Int
    public var clearance: Double?
    public var trackWidth: Double?
    public var viaDiameter: Double?
    public var viaDrill: Double?
    public var diffPairWidth: Double?
    public var diffPairGap: Double?
}

public enum ProjectParseError: Error, CustomStringConvertible {
    case notJSON
    public var description: String { "not a KiCad project file (expected JSON)" }
}

public enum ProjectParser {
    public static func parse(contentsOf url: URL) throws -> Project {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> Project {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectParseError.notJSON
        }
        let board = root["board"] as? [String: Any]
        let design = board?["design_settings"] as? [String: Any]
        var rules: [String: Double] = [:]
        for (k, v) in (design?["rules"] as? [String: Any]) ?? [:] {
            if let d = number(v) { rules[k] = d }
        }

        let netSettings = root["net_settings"] as? [String: Any]
        let classes = ((netSettings?["classes"] as? [[String: Any]]) ?? []).map { c in
            NetClass(
                name: c["name"] as? String ?? "",
                priority: number(c["priority"]).map { Int($0) } ?? Int.max,
                clearance: number(c["clearance"]),
                trackWidth: number(c["track_width"]),
                viaDiameter: number(c["via_diameter"]),
                viaDrill: number(c["via_drill"]),
                diffPairWidth: number(c["diff_pair_width"]),
                diffPairGap: number(c["diff_pair_gap"])
            )
        }
        let patterns: [(pattern: String, netClass: String)] = ((netSettings?["netclass_patterns"] as? [[String: Any]]) ?? []).compactMap { p in
            guard let pat = p["pattern"] as? String, let nc = p["netclass"] as? String else { return nil }
            return (pattern: pat, netClass: nc)
        }
        var assignments: [String: [String]] = [:]
        for (net, v) in (netSettings?["netclass_assignments"] as? [String: Any]) ?? [:] {
            if let s = v as? String { assignments[net] = [s] }
            else if let a = v as? [String] { assignments[net] = a }
        }
        return Project(rules: rules, netClasses: classes, netClassPatterns: patterns, netClassAssignments: assignments)
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

// MARK: - Net class resolution

public struct NetClassResolution: Equatable, Sendable {
    /// The class that wins by priority.
    public var effective: String
    /// Every class whose pattern or assignment matched; empty means the net fell back to Default.
    public var matched: [String]
}

public extension Project {
    /// Resolves the net class of `net` the way KiCad does: explicit assignments
    /// from the schematic first, then patterns matched against the **full**
    /// net name (wildcard or regular expression, anchored at both ends),
    /// then `Default`.
    func resolveNetClass(for net: String) -> NetClassResolution {
        var matched: [String] = netClassAssignments[net] ?? []
        for (pattern, nc) in netClassPatterns where !matched.contains(nc) {
            if NetPattern.matches(pattern: pattern, name: net) { matched.append(nc) }
        }
        let best = matched
            .compactMap { netClass(named: $0) }
            .min { $0.priority < $1.priority }
        return NetClassResolution(effective: best?.name ?? matched.first ?? "Default", matched: matched)
    }
}

public enum NetPattern {
    /// Anchored match of a KiCad net class pattern: true if it matches as a
    /// wildcard (`*`, `?`) or as a regular expression.
    public static func matches(pattern: String, name: String) -> Bool {
        wildcard(pattern, name) || regex(pattern, name)
    }

    static func wildcard(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern), s = Array(name)
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func regex(_ pattern: String, _ name: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        return re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
