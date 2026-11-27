import Foundation

// MARK: - Findings

/// Which set of rules a finding comes from. KiCad rules are the board's own
/// (board setup, net classes, custom rules); fab rules come from a fab profile.
public enum CheckSuite: Hashable, Sendable {
    case kicad
    case fab(id: String, name: String)

    public var title: String {
        switch self {
        case .kicad: return "KiCad rules"
        case .fab(_, let name): return name
        }
    }
}

public enum CheckKind: String, CaseIterable, Sendable {
    case clearance, holeClearance, holeToHole, edgeClearance
    case trackWidth, viaDiameter, viaDrill, viaAnnularRing
    case padDrill, padAnnularRing, slotWidth
    case silkLineWidth, textHeight, textThickness, silkToPad
    case boardThickness, ruleNotChecked

    public var title: String {
        switch self {
        case .clearance: return "Copper clearance"
        case .holeClearance: return "Hole to copper"
        case .holeToHole: return "Hole to hole"
        case .edgeClearance: return "Copper to board edge"
        case .trackWidth: return "Track width"
        case .viaDiameter: return "Via diameter"
        case .viaDrill: return "Via drill"
        case .viaAnnularRing: return "Via annular ring"
        case .padDrill: return "Pad drill"
        case .padAnnularRing: return "Pad annular ring"
        case .slotWidth: return "Slot width"
        case .silkLineWidth: return "Silkscreen line width"
        case .textHeight: return "Text height"
        case .textThickness: return "Text thickness"
        case .silkToPad: return "Silkscreen to pad"
        case .boardThickness: return "Board thickness"
        case .ruleNotChecked: return "Rules not checked"
        }
    }
}

public enum FindingSeverity: Int, Comparable, Sendable {
    case error = 0, warning, info
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String { ["Error", "Warning", "Info"][rawValue] }
}

/// The rule a finding was measured against, and where that rule comes from.
public struct RuleReference: Sendable {
    /// e.g. `Custom rule "PoE isolation"` or `JLCPCB: Pad to track`.
    public var title: String
    /// The fab's wording and the date it was checked, or the file the rule is in.
    public var detail: String?
    public var url: String?
    /// False for fab values that were not read word for word from the fab's page.
    public var verified: Bool
}

/// One problem found by the deterministic checks.
public struct Finding: Identifiable, Sendable {
    public var id: Int
    public var suite: CheckSuite
    public var kind: CheckKind
    public var severity: FindingSeverity
    public var message: String
    /// The measured value and the limit, mm.
    public var actual: Double?
    public var required: Double?
    public var rule: RuleReference
    /// Where to look: the closest point, and the area of the items involved.
    public var location: Point
    public var area: Rect
    public var layer: String?
    public var items: [BoardItem]
}

/// The result of one run of the checks.
public struct CheckReport: Sendable {
    public var findings: [Finding]
    /// Short descriptions of each rule source that was applied.
    public var applied: [String]
    public var profile: FabProfile?
    public var seconds: Double

    public func count(_ severity: FindingSeverity) -> Int { findings.filter { $0.severity == severity }.count }
}

// MARK: - The checker

/// Runs the deterministic design checks on a board: the board's own KiCad
/// rules, and optionally a fab profile. No guessing: a rule that cannot be
/// evaluated is reported as not checked.
public struct DesignChecker {
    public let input: ReviewInput
    public let profile: FabProfile?

    public init(input: ReviewInput, profile: FabProfile?) {
        self.input = input
        self.profile = profile
    }

    public func run() -> CheckReport {
        let start = Date()
        var run = Run(input: input, profile: profile)
        run.perform()
        run.findings.sort {
            ($0.severity, $0.kind.title, $0.location.y, $0.location.x) < ($1.severity, $1.kind.title, $1.location.y, $1.location.x)
        }
        for i in run.findings.indices { run.findings[i].id = i }
        return CheckReport(findings: run.findings, applied: run.applied, profile: profile, seconds: Date().timeIntervalSince(start))
    }
}

private struct Owner {
    var item: BoardItem?
    var net: String?
    var type: String
    var label: String
    var zoneClearance: Double?
    var bounds: Rect
}

private struct Limit {
    var value: Double
    var rule: RuleReference
    var severity: FindingSeverity = .error
}

private struct CompiledRule {
    var rule: CustomRule
    var condition: RuleExpression?
}

private struct Run {
    let input: ReviewInput
    let board: Board
    let profile: FabProfile?
    var findings: [Finding] = []
    var applied: [String] = []

    var owners: [Owner] = []
    var ownerOf: [BoardItem: Int] = [:]
    /// Copper shapes per layer: (owner index, shape).
    var copper: [String: [(owner: Int, shape: CheckShape)]] = [:]
    var holes: [(owner: Int, shape: CheckShape, kind: HoleKind)] = []
    var compiled: [CompiledRule] = []
    var netClassCache: [String: String] = [:]
    var clearanceCache: [String: Limit?] = [:]

    enum HoleKind { case via, pth, npth }

    init(input: ReviewInput, profile: FabProfile?) {
        self.input = input
        self.board = input.board
        self.profile = profile
    }

    var rules: [String: Double] { input.project?.rules ?? [:] }

    // MARK: Setup

    mutating func perform() {
        compileRules()
        collectShapes()
        if input.project != nil { applied.append("Board setup and net classes from the .kicad_pro") }
        if let n = input.customRules?.rules.count, n > 0 { applied.append("\(n) custom rules from the .kicad_dru") }
        if let p = profile { applied.append("\(p.name) profile (\(p.scope)), checked \(p.checked)") }

        checkClearances()
        checkHoleClearances()
        checkHoleToHole()
        checkEdgeClearance()
        checkTracks()
        checkVias()
        checkPads()
        checkSilkscreen()
        checkTexts()
        checkBoardThickness()

        // A fab's silkscreen limits are about legibility: the board still works, so these stay warnings.
        let silkKinds: Set<CheckKind> = [.silkLineWidth, .textHeight, .textThickness, .silkToPad]
        for i in findings.indices where findings[i].suite != .kicad && silkKinds.contains(findings[i].kind) && findings[i].severity == .error {
            findings[i].severity = .warning
        }
    }

    mutating func compileRules() {
        let supported: Set<String> = ["clearance", "hole_clearance", "hole_to_hole", "edge_clearance", "track_width",
                                      "hole_size", "annular_width", "via_diameter", "text_height", "text_thickness"]
        for rule in input.customRules?.rules ?? [] {
            if rule.severity?.lowercased() == "ignore" { continue }
            var condition: RuleExpression?
            if let text = rule.condition {
                do { condition = try RuleExpression.parse(text) }
                catch {
                    notChecked(rule.name, reason: "its condition uses something this checker does not understand (\(error)).")
                    continue
                }
            }
            for c in rule.constraints where !supported.contains(c.type) {
                notChecked(rule.name, reason: "the \(c.type) constraint is not checked here. Run KiCad's DRC for it.")
            }
            compiled.append(CompiledRule(rule: rule, condition: condition))
        }
    }

    mutating func notChecked(_ name: String, reason: String) {
        let b = board.outlineBounds ?? Rect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        findings.append(Finding(id: 0, suite: .kicad, kind: .ruleNotChecked, severity: .info,
                                message: "Custom rule \"\(name)\" was not checked: \(reason)",
                                rule: RuleReference(title: "Custom rule \"\(name)\"", detail: ".kicad_dru", url: nil, verified: true),
                                location: b.center, area: b, layer: nil, items: []))
    }

    func netLabel(_ net: String?) -> String { net.map { $0.isEmpty ? "no net" : $0 } ?? "no net" }

    mutating func collectShapes() {
        for (i, t) in board.tracks.enumerated() {
            let shape = CheckShape.polyline(t.centerline, radius: t.width / 2)
            let o = add(Owner(item: .track(i), net: t.net, type: "Track", label: "track (\(netLabel(t.net)))", bounds: shape.bounds))
            copper[t.layer, default: []].append((o, shape))
        }
        for (i, v) in board.vias.enumerated() {
            let shape = CheckShape.circle(v.position, radius: v.size / 2)
            let o = add(Owner(item: .via(i), net: v.net, type: "Via", label: "via (\(netLabel(v.net)))", bounds: shape.bounds))
            for l in v.spannedLayers { copper[l, default: []].append((o, shape)) }
            holes.append((o, .circle(v.position, radius: v.drill / 2), .via))
        }
        for (f, fp) in board.footprints.enumerated() {
            for (p, pad) in fp.pads.enumerated() {
                let shape = CheckShape.pad(pad)
                let o = add(Owner(item: .pad(footprint: f, pad: p), net: pad.net, type: "Pad",
                                  label: "pad \(fp.reference)-\(pad.number) (\(netLabel(pad.net)))", bounds: shape.bounds))
                if pad.kind != .npThruHole {
                    for l in pad.copperLayers { copper[l, default: []].append((o, shape)) }
                }
                if let h = CheckShape.hole(of: pad) { holes.append((o, h, pad.isPlated ? .pth : .npth)) }
            }
        }
        for (i, z) in board.zones.enumerated() where !z.isRuleArea {
            let pts = z.filledPolygons.flatMap(\.points)
            guard let b = Rect.enclosing(pts) else { continue }
            let name = z.name.map { "zone \"\($0)\"" } ?? "zone"
            let o = add(Owner(item: .zone(i), net: z.net, type: "Zone", label: "\(name) fill (\(netLabel(z.net)))",
                              zoneClearance: z.clearance, bounds: b))
            for fill in z.filledPolygons where fill.points.count > 1 {
                let closed = fill.points + [fill.points[0]]
                for (a, c) in zip(closed, closed.dropFirst()) {
                    copper[fill.layer, default: []].append((o, CheckShape(segments: [(a, c)], radius: 0)))
                }
            }
        }
    }

    mutating func add(_ o: Owner) -> Int {
        owners.append(o)
        if let item = o.item { ownerOf[item] = owners.count - 1 }
        return owners.count - 1
    }

    // MARK: Rule lookup

    mutating func netClass(_ net: String?) -> String {
        guard let net, let project = input.project else { return "Default" }
        if let c = netClassCache[net] { return c }
        let c = project.resolveNetClass(for: net).effective
        netClassCache[net] = c
        return c
    }

    mutating func exprItem(_ o: Owner, layer: String?) -> RuleExpression.Item {
        RuleExpression.Item(netName: o.net, netClass: netClass(o.net), type: o.type, layer: layer)
    }

    static func layerMatches(_ filter: String?, _ layer: String?) -> Bool {
        guard let filter else { return true }
        guard let layer else { return false }
        let f = filter.lowercased()
        if f == "outer" { return layer == "F.Cu" || layer == "B.Cu" }
        if f == "inner" { return layer.hasPrefix("In") && layer.hasSuffix(".Cu") }
        let aliases = ["silkscreen": "silks", "courtyard": "crtyd", "adhesive": "adhes", "user.drawings": "dwgs.user",
                       "user.comments": "cmts.user", "soldermask": "mask", "paste": "paste"]
        func normal(_ s: String) -> String {
            var parts = s.lowercased().split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, let a = aliases[parts[1]] { parts[1] = a }
            return parts.joined(separator: ".")
        }
        let l = normal(layer)
        if f.hasPrefix("?.") {
            let rest = normal("x." + f.dropFirst(2)).dropFirst(2)
            return l == "f." + rest || l == "b." + rest
        }
        return normal(filter) == l
    }

    /// The last matching custom rule with a `min` for `constraint` (KiCad: later rules win).
    mutating func customMin(_ constraint: String, a: Owner, b: Owner?, layer: String?) -> Limit? {
        let ia = exprItem(a, layer: layer)
        let ib = b.map { exprItem($0, layer: layer) }
        for c in compiled.reversed() {
            guard let k = c.rule.constraints.first(where: { $0.type == constraint }), let min = k.min,
                  Self.layerMatches(c.rule.layer, layer) else { continue }
            var matches = true
            if let cond = c.condition {
                matches = cond.evaluate(a: ia, b: ib) || (ib.map { cond.evaluate(a: $0, b: ia) } ?? false)
            }
            guard matches else { continue }
            let sev: FindingSeverity = c.rule.severity?.lowercased() == "warning" ? .warning : .error
            return Limit(value: min, rule: RuleReference(title: "Custom rule \"\(c.rule.name)\"", detail: ".kicad_dru", url: nil, verified: true), severity: sev)
        }
        return nil
    }

    func boardLimit(_ key: String, _ title: String) -> Limit? {
        guard let v = rules[key], v > 0 else { return nil }
        return Limit(value: v, rule: RuleReference(title: "Board setup: \(title)", detail: ".kicad_pro (\(key))", url: nil, verified: true))
    }

    /// KiCad's way: the custom rule, else the stricter net class, floored by the board minimum.
    func kicadLimit(custom: Limit?, fallback: Limit?, floor: Limit?) -> Limit? {
        var l = custom ?? fallback
        if let f = floor, f.value > (l?.value ?? -1) { l = f }
        return l
    }

    func fab(_ id: FabProfile.RuleID) -> FabProfile.Rule? { profile?.rule(id) }

    func fabReference(_ r: FabProfile.Rule) -> RuleReference {
        let src = profile?.source(of: r)
        let label = r.id.replacingOccurrences(of: "_", with: " ")
        return RuleReference(title: "\(profile?.name ?? "Fab"): \(label)",
                             detail: "\"\(r.quote)\" (\(src?.title ?? "fab page"), checked \(profile?.checked ?? "?"))"
                                + (r.verified ? "" : ". Not confirmed word for word on the page."),
                             url: src?.url, verified: r.verified)
    }

    var fabSuite: CheckSuite { .fab(id: profile?.id ?? "", name: profile?.name ?? "Fab") }

    // MARK: Reporting

    /// Reports `actual` against a minimum KiCad limit and a fab rule.
    mutating func report(_ kind: CheckKind, actual: Double, kicad: Limit?, fab fabRule: FabProfile.Rule?,
                         what: String, layer: String?, at: Point, area: Rect, items: [BoardItem],
                         maximum: Bool = false) {
        let eps = 1e-6
        func fails(_ limit: Double) -> Bool { maximum ? actual > limit + eps : actual < limit - eps }
        let verb = maximum ? "at most" : "at least"
        if let k = kicad, fails(k.value) {
            findings.append(Finding(id: 0, suite: .kicad, kind: kind, severity: k.severity,
                                    message: "\(what) is \(mm(actual)); needs \(verb) \(mm(k.value)).",
                                    actual: actual, required: k.value, rule: k.rule,
                                    location: at, area: area, layer: layer, items: items))
        }
        if let r = fabRule {
            if fails(r.value) {
                findings.append(Finding(id: 0, suite: fabSuite, kind: kind, severity: r.verified ? .error : .warning,
                                        message: "\(what) is \(mm(actual)); \(profile?.name ?? "the fab") needs \(verb) \(mm(r.value)).",
                                        actual: actual, required: r.value, rule: fabReference(r),
                                        location: at, area: area, layer: layer, items: items))
            } else if let rec = r.recommended, fails(rec) {
                findings.append(Finding(id: 0, suite: fabSuite, kind: kind, severity: .warning,
                                        message: "\(what) is \(mm(actual)); \(profile?.name ?? "the fab") recommends \(verb) \(mm(rec)) (limit \(mm(r.value))).",
                                        actual: actual, required: rec, rule: fabReference(r),
                                        location: at, area: area, layer: layer, items: items))
            }
        }
    }

    func mm(_ v: Double) -> String { String(format: "%.3f mm", v) }

    func area(_ a: Owner, _ b: Owner?) -> Rect {
        guard let b else { return a.bounds }
        let za = a.type == "Zone", zb = b.type == "Zone"
        // Zone fills are large; frame the other item instead.
        if za && !zb { return b.bounds }
        if zb && !za { return a.bounds }
        return a.bounds.union(b.bounds)
    }

    // MARK: Copper clearance

    mutating func clearanceLimit(_ a: Owner, _ b: Owner, layer: String) -> Limit? {
        let key = "\(a.net ?? "")|\(a.type)|\(b.net ?? "")|\(b.type)|\(layer)|\(a.zoneClearance ?? -1)|\(b.zoneClearance ?? -1)"
        if let c = clearanceCache[key] { return c }
        let custom = customMin("clearance", a: a, b: b, layer: layer)
        var fallback: Limit?
        if let project = input.project {
            for o in [a, b] {
                let name = netClass(o.net)
                if let v = project.netClass(named: name)?.clearance, v > (fallback?.value ?? -1) {
                    fallback = Limit(value: v, rule: RuleReference(title: "Net class \(name): clearance", detail: ".kicad_pro", url: nil, verified: true))
                }
                if let z = o.zoneClearance, z > (fallback?.value ?? -1) {
                    fallback = Limit(value: z, rule: RuleReference(title: "Zone clearance", detail: "zone settings in the .kicad_pcb", url: nil, verified: true))
                }
            }
        }
        let l = kicadLimit(custom: custom, fallback: fallback, floor: boardLimit("min_clearance", "minimum clearance"))
        clearanceCache[key] = l
        return l
    }

    func fabClearanceRule(_ a: Owner, _ b: Owner) -> FabProfile.Rule? {
        let types = Set([a.type, b.type])
        if types == ["Pad"] { return fab(.minSMDPadToPad) ?? fab(.minClearance) }
        if types.contains("Pad") && (types.contains("Track") || types.contains("Via")) { return fab(.minPadToTrack) ?? fab(.minClearance) }
        return fab(.minClearance)
    }

    /// The largest clearance any rule could ask for, to size the search.
    var maxClearance: Double {
        var m = rules["min_clearance"] ?? 0
        for nc in input.project?.netClasses ?? [] { m = max(m, nc.clearance ?? 0) }
        for z in board.zones { m = max(m, z.clearance ?? 0) }
        for c in compiled { for k in c.rule.constraints where k.type == "clearance" { m = max(m, k.min ?? 0) } }
        for id in [FabProfile.RuleID.minClearance, .minPadToTrack, .minSMDPadToPad] {
            if let r = fab(id) { m = max(m, r.recommended ?? r.value) }
        }
        return max(m, 0.01)
    }

    static func differentNets(_ a: Owner, _ b: Owner) -> Bool {
        guard let na = a.net, let nb = b.net, !na.isEmpty, !nb.isEmpty else { return true }
        return na != nb
    }

    mutating func checkClearances() {
        let margin = maxClearance
        struct PairKey: Hashable { var a: Int, b: Int; var layer: String }
        var best: [PairKey: (Double, Point)] = [:]
        for (layer, shapes) in copper {
            var grid = SpatialGrid(cell: max(margin, 0.5))
            for (i, s) in shapes.enumerated() { grid.insert(i, bounds: s.shape.bounds) }
            var seen = [Int](repeating: -1, count: shapes.count)
            for (i, s) in shapes.enumerated() {
                let oa = owners[s.owner]
                for j in grid.query(s.shape.bounds, margin: margin) where j > i && seen[j] != i {
                    seen[j] = i
                    let t = shapes[j]
                    guard t.owner != s.owner else { continue }
                    let ob = owners[t.owner]
                    guard Self.differentNets(oa, ob), s.shape.bounds.overlaps(t.shape.bounds, margin: margin) else { continue }
                    let g = CheckShape.gap(s.shape, t.shape)
                    guard g.distance < margin else { continue }
                    let key = PairKey(a: min(s.owner, t.owner), b: max(s.owner, t.owner), layer: layer)
                    if g.distance < (best[key]?.0 ?? .infinity) { best[key] = (g.distance, g.at) }
                }
            }
            // An item lying inside another net's zone fill (shorted, or the fill is stale).
            let fills = board.zones.enumerated().flatMap { (zi, z) -> [(Int, [Point], Rect)] in
                guard !z.isRuleArea else { return [] }
                return z.filledPolygons.filter { $0.layer == layer }.compactMap { f in
                    Rect.enclosing(f.points).map { (zi, f.points, $0) }
                }
            }
            guard !fills.isEmpty else { continue }
            let zoneOwner = Dictionary(owners.enumerated().compactMap { (i, o) -> (Int, Int)? in
                if case .zone(let z)? = o.item { return (z, i) } else { return nil }
            }, uniquingKeysWith: { a, _ in a })
            var tested = Set<Int>()
            for s in shapes where owners[s.owner].type != "Zone" && tested.insert(s.owner).inserted {
                guard let p = s.shape.segments.first?.0 else { continue }
                for (zi, pts, box) in fills {
                    guard let zo = zoneOwner[zi], Self.differentNets(owners[s.owner], owners[zo]),
                          p.x >= box.minX, p.x <= box.maxX, p.y >= box.minY, p.y <= box.maxY,
                          Shapes.contains(pts, p) else { continue }
                    best[PairKey(a: min(s.owner, zo), b: max(s.owner, zo), layer: layer)] = (0, p)
                }
            }
        }
        for (key, (gap, at)) in best.sorted(by: { ($0.key.layer, $0.key.a, $0.key.b) < ($1.key.layer, $1.key.a, $1.key.b) }) {
            let a = owners[key.a], b = owners[key.b]
            let what = gap <= 0 ? "Overlap: gap between \(a.label) and \(b.label) on \(key.layer)" : "Gap between \(a.label) and \(b.label) on \(key.layer)"
            let limit = clearanceLimit(a, b, layer: key.layer)
            report(.clearance, actual: gap, kicad: limit, fab: fabClearanceRule(a, b),
                   what: what, layer: key.layer, at: at, area: area(a, b), items: [a.item, b.item].compactMap { $0 })
        }
    }

    // MARK: Holes

    mutating func checkHoleClearances() {
        let holeFloor = boardLimit("min_hole_clearance", "minimum hole clearance")
        var margin = max(holeFloor?.value ?? 0, 0.01)
        for c in compiled { for k in c.rule.constraints where k.type == "hole_clearance" { margin = max(margin, k.min ?? 0) } }
        for id in [FabProfile.RuleID.minViaHoleToTrack, .minPTHHoleToTrack, .minNPTHHoleToTrack] {
            if let r = fab(id) { margin = max(margin, r.recommended ?? r.value) }
        }
        struct Key: Hashable { var hole: Int, copper: Int }
        var best: [Key: (Double, Point, String, HoleKind)] = [:]
        for (layer, shapes) in copper {
            var grid = SpatialGrid(cell: max(margin * 2, 0.5))
            for (i, s) in shapes.enumerated() { grid.insert(i, bounds: s.shape.bounds) }
            for h in holes {
                let oh = owners[h.owner]
                for j in Set(grid.query(h.shape.bounds, margin: margin)) {
                    let s = shapes[j]
                    guard s.owner != h.owner else { continue }
                    let oc = owners[s.owner]
                    guard h.kind == .npth || Self.differentNets(oh, oc) else { continue }
                    let g = CheckShape.gap(h.shape, s.shape)
                    guard g.distance < margin else { continue }
                    let key = Key(hole: h.owner, copper: s.owner)
                    if g.distance < (best[key]?.0 ?? .infinity) { best[key] = (g.distance, g.at, layer, h.kind) }
                }
            }
        }
        for (key, (gap, at, layer, kind)) in best.sorted(by: { ($0.key.hole, $0.key.copper) < ($1.key.hole, $1.key.copper) }) {
            let h = owners[key.hole], c = owners[key.copper]
            let custom = customMin("hole_clearance", a: h, b: c, layer: layer)
            let kicad = kicadLimit(custom: custom, fallback: nil, floor: holeFloor)
            var fabRule: FabProfile.Rule?
            if c.type == "Track" {
                switch kind {
                case .via: fabRule = fab(.minViaHoleToTrack)
                case .pth: fabRule = fab(.minPTHHoleToTrack)
                case .npth: fabRule = fab(.minNPTHHoleToTrack)
                }
            }
            report(.holeClearance, actual: gap, kicad: kicad, fab: fabRule,
                   what: "Gap from the hole of \(h.label) to \(c.label) on \(layer)", layer: layer, at: at,
                   area: area(h, c), items: [h.item, c.item].compactMap { $0 })
        }
    }

    mutating func checkHoleToHole() {
        let boardMin = boardLimit("min_hole_to_hole", "minimum hole to hole")
        var margin = max(boardMin?.value ?? 0, 0.01)
        for c in compiled { for k in c.rule.constraints where k.type == "hole_to_hole" { margin = max(margin, k.min ?? 0) } }
        for id in [FabProfile.RuleID.minViaHoleToHole, .minPadHoleToHole] { if let r = fab(id) { margin = max(margin, r.value) } }
        var grid = SpatialGrid(cell: max(margin * 2, 0.5))
        for (i, h) in holes.enumerated() { grid.insert(i, bounds: h.shape.bounds) }
        for (i, h) in holes.enumerated() {
            for j in Set(grid.query(h.shape.bounds, margin: margin)) where j > i {
                let k = holes[j]
                guard k.owner != h.owner else { continue }
                let g = CheckShape.gap(h.shape, k.shape)
                guard g.distance < margin else { continue }
                let a = owners[h.owner], b = owners[k.owner]
                let custom = customMin("hole_to_hole", a: a, b: b, layer: nil)
                let kicad = kicadLimit(custom: custom, fallback: nil, floor: boardMin)
                let fabRule = h.kind == .via && k.kind == .via ? fab(.minViaHoleToHole) : fab(.minPadHoleToHole)
                report(.holeToHole, actual: g.distance, kicad: kicad, fab: fabRule,
                       what: "Gap between the holes of \(a.label) and \(b.label)", layer: nil, at: g.at,
                       area: a.bounds.union(b.bounds), items: [a.item, b.item].compactMap { $0 })
            }
        }
    }

    // MARK: Board edge

    mutating func checkEdgeClearance() {
        let edges = board.outline.flatMap { g -> [(Point, Point)] in
            let pts = g.polyline
            return zip(pts, pts.dropFirst()).map { ($0, $1) }
        }
        guard !edges.isEmpty else { return }
        let boardMin = boardLimit("min_copper_edge_clearance", "minimum copper to edge clearance")
        var margin = max(boardMin?.value ?? 0, 0.01)
        for c in compiled { for k in c.rule.constraints where k.type == "edge_clearance" { margin = max(margin, k.min ?? 0) } }
        if let r = fab(.minCopperToEdge) { margin = max(margin, r.recommended ?? r.value) }
        let edgeShapes = edges.map { CheckShape(segments: [$0], radius: 0) }
        var grid = SpatialGrid(cell: max(margin * 2, 1))
        for (i, e) in edgeShapes.enumerated() { grid.insert(i, bounds: e.bounds) }
        struct Key: Hashable { var owner: Int; var layer: String }
        var best: [Key: (Double, Point)] = [:]
        for (layer, shapes) in copper {
            for s in shapes {
                for j in Set(grid.query(s.shape.bounds, margin: margin)) {
                    let g = CheckShape.gap(s.shape, edgeShapes[j])
                    guard g.distance < margin else { continue }
                    let key = Key(owner: s.owner, layer: layer)
                    if g.distance < (best[key]?.0 ?? .infinity) { best[key] = (g.distance, g.at) }
                }
            }
        }
        // One finding per item: its closest layer.
        var perOwner: [Int: (Double, Point, String)] = [:]
        for (k, v) in best where v.0 < (perOwner[k.owner]?.0 ?? .infinity) { perOwner[k.owner] = (v.0, v.1, k.layer) }
        for (o, (gap, at, layer)) in perOwner.sorted(by: { $0.key < $1.key }) {
            let owner = owners[o]
            let custom = customMin("edge_clearance", a: owner, b: nil, layer: layer)
            let kicad = kicadLimit(custom: custom, fallback: nil, floor: boardMin)
            let box = Rect(minX: at.x - 1, minY: at.y - 1, maxX: at.x + 1, maxY: at.y + 1)
            report(.edgeClearance, actual: gap, kicad: kicad, fab: fab(.minCopperToEdge),
                   what: "Gap from \(owner.label) to the board edge on \(layer)", layer: layer, at: at,
                   area: owner.type == "Zone" ? box : owner.bounds.union(box), items: [owner.item].compactMap { $0 })
        }
    }

    // MARK: Single items

    mutating func checkTracks() {
        let boardMin = boardLimit("min_track_width", "minimum track width")
        for (i, t) in board.tracks.enumerated() {
            let o = owners[ownerOf[.track(i)]!]
            let custom = customMin("track_width", a: o, b: nil, layer: t.layer)
            let kicad = kicadLimit(custom: custom, fallback: nil, floor: boardMin)
            let at = t.centerline[t.centerline.count / 2]
            report(.trackWidth, actual: t.width, kicad: kicad, fab: fab(.minTrackWidth),
                   what: "Width of \(o.label) on \(t.layer)", layer: t.layer, at: at, area: o.bounds, items: [.track(i)])
        }
    }

    mutating func checkVias() {
        for (i, v) in board.vias.enumerated() {
            let o = owners[ownerOf[.via(i)]!]
            let micro = v.kind == .micro
            let layer = v.endLayers.first
            let diaBoard = micro ? boardLimit("min_microvia_diameter", "minimum micro via diameter") : boardLimit("min_via_diameter", "minimum via diameter")
            let drillBoard = micro ? boardLimit("min_microvia_drill", "minimum micro via hole") : boardLimit("min_through_hole_diameter", "minimum through hole")
            let customDia = customMin("via_diameter", a: o, b: nil, layer: layer)
            let customHole = customMin("hole_size", a: o, b: nil, layer: layer)
            let customRing = customMin("annular_width", a: o, b: nil, layer: layer)
            report(.viaDiameter, actual: v.size,
                   kicad: kicadLimit(custom: customDia, fallback: nil, floor: diaBoard),
                   fab: fab(.minViaDiameter), what: "Diameter of \(o.label)", layer: nil, at: v.position, area: o.bounds, items: [.via(i)])
            report(.viaDrill, actual: v.drill,
                   kicad: kicadLimit(custom: customHole, fallback: nil, floor: drillBoard),
                   fab: fab(.minViaDrill), what: "Drill of \(o.label)", layer: nil, at: v.position, area: o.bounds, items: [.via(i)])
            report(.viaAnnularRing, actual: v.annularRing,
                   kicad: kicadLimit(custom: customRing, fallback: nil,
                                     floor: boardLimit("min_via_annular_width", "minimum via annular width")),
                   fab: fab(.minViaAnnularRing), what: "Annular ring of \(o.label)", layer: nil, at: v.position, area: o.bounds, items: [.via(i)])
        }
    }

    mutating func checkPads() {
        for (f, fp) in board.footprints.enumerated() {
            for (p, pad) in fp.pads.enumerated() {
                guard let drill = pad.drill else { continue }
                let item = BoardItem.pad(footprint: f, pad: p)
                let o = owners[ownerOf[item]!]
                let plated = pad.isPlated
                let hole = drill.minimumSize
                let customHole = customMin("hole_size", a: o, b: nil, layer: nil)
                let holeFloor = boardLimit("min_through_hole_diameter", "minimum through hole")
                if drill.isSlot {
                    report(.slotWidth, actual: hole, kicad: kicadLimit(custom: customHole, fallback: nil, floor: holeFloor),
                           fab: plated ? fab(.minPlatedSlot) : fab(.minNPTHSlot),
                           what: "Slot width of \(o.label)", layer: nil, at: pad.position, area: o.bounds, items: [item])
                } else {
                    report(.padDrill, actual: hole, kicad: kicadLimit(custom: customHole, fallback: nil, floor: holeFloor),
                           fab: plated ? fab(.minPTHDrill) : fab(.minNPTHDrill),
                           what: "Drill of \(o.label)", layer: nil, at: pad.position, area: o.bounds, items: [item])
                }
                if plated, let maxRule = fab(.maxPTHDrill) {
                    report(.padDrill, actual: max(drill.diameter, drill.slotHeight ?? 0), kicad: nil, fab: maxRule,
                           what: "Drill of \(o.label)", layer: nil, at: pad.position, area: o.bounds, items: [item], maximum: true)
                }
                if plated, pad.shape != .custom {
                    let ring: Double
                    if drill.isSlot {
                        ring = min(pad.size.width - drill.diameter, pad.size.height - (drill.slotHeight ?? drill.diameter)) / 2
                    } else {
                        ring = (min(pad.size.width, pad.size.height) - drill.diameter) / 2
                    }
                    let customRing = customMin("annular_width", a: o, b: nil, layer: nil)
                    report(.padAnnularRing, actual: ring, kicad: customRing,
                           fab: fab(.minPTHAnnularRing), what: "Annular ring of \(o.label)", layer: nil,
                           at: pad.position, area: o.bounds, items: [item])
                }
            }
        }
    }

    // MARK: Silkscreen and text

    mutating func checkSilkscreen() {
        guard profile != nil else { return }
        let width = fab(.minSilkLineWidth), toPad = fab(.minSilkToPad)
        for side in ["F", "B"] {
            let layer = "\(side).SilkS"
            // Thinnest line per footprint, and per board graphic.
            var silk: [(shape: CheckShape, owner: String, item: BoardItem?, width: Double)] = []
            for (f, fp) in board.footprints.enumerated() {
                for g in fp.graphics where g.layer == layer && g.width > 0 {
                    silk.append((.polyline(g.polyline, radius: g.width / 2), "silkscreen of \(fp.reference)", .footprint(f), g.width))
                }
            }
            for g in board.graphics where g.layer == layer && g.width > 0 {
                silk.append((.polyline(g.polyline, radius: g.width / 2), "board silkscreen line", nil, g.width))
            }
            if let width {
                var thinnest: [String: Int] = [:]
                for (i, s) in silk.enumerated() {
                    let key = s.item == nil ? "board-\(i)" : s.owner
                    if s.width < silk[thinnest[key] ?? i].width || thinnest[key] == nil { thinnest[key] = i }
                }
                for i in thinnest.values.sorted() {
                    let s = silk[i]
                    report(.silkLineWidth, actual: s.width, kicad: nil, fab: width, what: "Thinnest line of the \(s.owner)",
                           layer: layer, at: s.shape.segments[0].0, area: s.shape.bounds, items: [s.item].compactMap { $0 })
                }
            }
            guard let toPad else { continue }
            var grid = SpatialGrid(cell: 1)
            for (i, s) in silk.enumerated() { grid.insert(i, bounds: s.shape.bounds) }
            for (f, fp) in board.footprints.enumerated() {
                for (p, pad) in fp.pads.enumerated() where pad.layers.contains("\(side).Cu") || pad.layers.contains("\(side).Mask") {
                    let shape = CheckShape.pad(pad)
                    var closest: (Double, Point, Int)?
                    for j in Set(grid.query(shape.bounds, margin: toPad.value)) {
                        let g = CheckShape.gap(shape, silk[j].shape)
                        if g.distance < (closest?.0 ?? toPad.value) { closest = (g.distance, g.at, j) }
                    }
                    guard let c = closest else { continue }
                    let (gap, at, j) = c
                    let item = BoardItem.pad(footprint: f, pad: p)
                    report(.silkToPad, actual: gap, kicad: nil, fab: toPad,
                           what: "Gap from pad \(fp.reference)-\(pad.number) to the \(silk[j].owner)", layer: layer, at: at,
                           area: shape.bounds.union(silk[j].shape.bounds), items: [item])
                }
            }
        }
    }

    mutating func checkTexts() {
        let heightFloor = boardLimit("min_text_height", "minimum text height")
        let thickFloor = boardLimit("min_text_thickness", "minimum text thickness")
        for t in board.texts where !t.hidden {
            let silk = t.layer.hasSuffix(".SilkS")
            guard silk || t.layer.hasSuffix(".Cu") else { continue }
            let o = Owner(item: nil, net: nil, type: "Text", label: "text \"\(t.text)\"", bounds: Rect(minX: t.position.x - 1, minY: t.position.y - 1, maxX: t.position.x + 1, maxY: t.position.y + 1))
            let ref = board.footprints.firstIndex { $0.reference == t.footprintReference && t.footprintReference != nil }
            let items: [BoardItem] = ref.map { [.footprint($0)] } ?? []
            if let h = t.height {
                let custom = customMin("text_height", a: o, b: nil, layer: t.layer)
                report(.textHeight, actual: h,
                       kicad: kicadLimit(custom: custom, fallback: nil, floor: heightFloor),
                       fab: silk ? fab(.minSilkTextHeight) : nil,
                       what: "Height of \(o.label) on \(t.layer)", layer: t.layer, at: t.position, area: o.bounds, items: items)
            }
            if let w = t.thickness {
                let custom = customMin("text_thickness", a: o, b: nil, layer: t.layer)
                report(.textThickness, actual: w,
                       kicad: kicadLimit(custom: custom, fallback: nil, floor: thickFloor),
                       fab: silk ? fab(.minSilkLineWidth) : nil,
                       what: "Stroke of \(o.label) on \(t.layer)", layer: t.layer, at: t.position, area: o.bounds, items: items)
            }
        }
    }

    mutating func checkBoardThickness() {
        guard let t = board.thickness, let b = board.outlineBounds else { return }
        report(.boardThickness, actual: t, kicad: nil, fab: fab(.minBoardThickness), what: "Board thickness",
               layer: nil, at: b.center, area: b, items: [])
        report(.boardThickness, actual: t, kicad: nil, fab: fab(.maxBoardThickness), what: "Board thickness",
               layer: nil, at: b.center, area: b, items: [], maximum: true)
    }
}
