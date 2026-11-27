import XCTest
@testable import KiCadKit

final class FabProfileTests: XCTestCase {
    func testBundledProfilesLoadAndCiteTheirSources() throws {
        let profiles = FabProfiles.bundled()
        XCTAssertEqual(profiles.map(\.id), ["jlcpcb", "pcbway"])
        for p in profiles {
            XCTAssertEqual(p.unknownRuleIDs, [], "\(p.id) has rule ids no check uses")
            XCTAssertEqual(p.checked, "2026-11-27")
            XCTAssertFalse(p.rules.isEmpty)
            for r in p.rules {
                let src = try XCTUnwrap(p.source(of: r), "\(p.id).\(r.id) cites an unknown source")
                XCTAssertTrue(src.url.hasPrefix("https://"))
                XCTAssertFalse(r.quote.isEmpty)
                XCTAssertGreaterThan(r.value, 0)
                if let rec = r.recommended { XCTAssertGreaterThan(rec, r.value, "\(p.id).\(r.id)") }
            }
        }
        let jlc = try FabProfiles.load(id: "jlcpcb")
        XCTAssertEqual(jlc.rule(.minTrackWidth)?.value, 0.09)
        XCTAssertEqual(jlc.rule(.minPadHoleToHole)?.value, 0.45)
    }
}

final class RuleExpressionTests: XCTestCase {
    func item(_ net: String?, _ type: String = "Track") -> RuleExpression.Item {
        RuleExpression.Item(netName: net, netClass: "Default", type: type, layer: "F.Cu")
    }

    func testPoEIsolationCondition() throws {
        let rules = try XCTUnwrap(BoardParserTests.input.customRules)
        let poe = try XCTUnwrap(rules.rules.first { $0.name == "PoE isolation" })
        let e = try RuleExpression.parse(try XCTUnwrap(poe.condition))
        XCTAssertTrue(e.evaluate(a: item("VPOE"), b: item("GND")))
        XCTAssertTrue(e.evaluate(a: item("/Power/PSU_EN"), b: item("GND")), "wildcard /Power/P*")
        XCTAssertFalse(e.evaluate(a: item("VPOE"), b: item("POE_VSS")), "both on the primary side")
        XCTAssertFalse(e.evaluate(a: item("VPOE"), b: item("/Ethernet/CHASSIS")))
        XCTAssertFalse(e.evaluate(a: item("VPOE"), b: item("unconnected-(U3-Pad4)")))
        XCTAssertFalse(e.evaluate(a: item("GND"), b: item("+3V3")))
        XCTAssertFalse(e.evaluate(a: item("VPOE"), b: nil), "B missing")
    }

    func testTypesAndUnsupported() throws {
        let e = try RuleExpression.parse("A.NetName == '/Ethernet/ETH_TX?' && B.Type == 'zone'")
        XCTAssertTrue(e.evaluate(a: item("/Ethernet/ETH_TXP"), b: item("GND", "Zone")))
        XCTAssertFalse(e.evaluate(a: item("/Ethernet/ETH_TXP"), b: item("GND", "Pad")))
        XCTAssertTrue(e.usesB)
        XCTAssertThrowsError(try RuleExpression.parse("A.intersectsArea('X')"))
        XCTAssertThrowsError(try RuleExpression.parse("A.Pad_Type == 'SMD'"))
    }
}

final class DesignCheckTests: XCTestCase {
    func track(_ y: Double, net: String, width: Double = 0.2, layer: String = "F.Cu") -> Track {
        Track(kind: .segment, start: Point(0, y), end: Point(10, y), width: width, layer: layer, net: net)
    }

    func run(_ board: Board, rules: [String: Double] = ["min_clearance": 0.15],
             custom: [CustomRule] = [], profile: String? = nil) throws -> CheckReport {
        let project = Project(rules: rules, netClasses: [], netClassPatterns: [], netClassAssignments: [:])
        let input = ReviewInput(board: board, project: project,
                                customRules: CustomRules(version: 1, rules: custom), warnings: [])
        return DesignChecker(input: input, profile: try profile.map { try FabProfiles.load(id: $0) }).run()
    }

    func testTrackClearance() throws {
        var b = Board(version: 20260206)
        // Edges 0.1 mm apart.
        b.tracks = [track(0, net: "A"), track(0.3, net: "B"), track(0.6, net: "B")]
        let r = try run(b)
        let clearance = r.findings.filter { $0.kind == .clearance }
        XCTAssertEqual(clearance.count, 1, "same-net tracks are never compared")
        XCTAssertEqual(try XCTUnwrap(clearance.first?.actual), 0.1, accuracy: 1e-9)
        XCTAssertEqual(clearance.first?.required, 0.15)
        XCTAssertEqual(clearance.first?.suite, .kicad)
        XCTAssertEqual(Set(clearance.first?.items ?? []), [.track(0), .track(1)])

        // JLCPCB allows 0.09 mm; PCBWay's 0.1 mm is met exactly.
        XCTAssertTrue(try run(b, profile: "jlcpcb").findings.filter { $0.suite != .kicad && $0.kind == .clearance }.isEmpty)
        XCTAssertTrue(try run(b, profile: "pcbway").findings.filter { $0.suite != .kicad && $0.kind == .clearance }.isEmpty)
        b.tracks[1] = track(0.29, net: "B")
        let fab = try run(b, profile: "pcbway").findings.filter { $0.suite != .kicad && $0.kind == .clearance }
        XCTAssertEqual(fab.count, 1)
        XCTAssertEqual(fab.first?.severity, .error)
        XCTAssertEqual(fab.first?.rule.url, "https://www.pcbway.com/capabilities.html")

        // Crossing tracks overlap.
        b.tracks = [track(0, net: "A"), Track(kind: .segment, start: Point(5, -5), end: Point(5, 5), width: 0.2, layer: "F.Cu", net: "B")]
        XCTAssertEqual(try run(b).findings.first { $0.kind == .clearance }?.actual, 0)
        // Different layers never clash.
        b.tracks = [track(0, net: "A"), track(0.3, net: "B", layer: "B.Cu")]
        XCTAssertTrue(try run(b).findings.filter { $0.kind == .clearance }.isEmpty)
    }

    func testCustomClearanceRuleWins() throws {
        var b = Board(version: 20260206)
        b.tracks = [track(0, net: "HV"), track(0.7, net: "LV")]
        let iso = CustomRule(name: "isolation", condition: "A.NetName == 'HV' && B.NetName != 'HV'", layer: nil, severity: nil,
                             constraints: [RuleConstraint(type: "clearance", min: 1.0, opt: nil, max: nil, arguments: [])])
        let r = try run(b, custom: [iso])
        let f = try XCTUnwrap(r.findings.first { $0.kind == .clearance })
        XCTAssertEqual(f.required, 1.0)
        XCTAssertEqual(f.rule.title, "Custom rule \"isolation\"")
        XCTAssertEqual(try XCTUnwrap(f.actual), 0.5, accuracy: 1e-9)
        // Unsupported conditions are reported, not guessed.
        let odd = CustomRule(name: "odd", condition: "A.insideCourtyard('U1')", layer: nil, severity: nil,
                             constraints: [RuleConstraint(type: "clearance", min: 1.0, opt: nil, max: nil, arguments: [])])
        let r2 = try run(b, custom: [odd])
        XCTAssertEqual(r2.findings.filter { $0.kind == .ruleNotChecked }.count, 1)
        XCTAssertTrue(r2.findings.filter { $0.kind == .clearance }.isEmpty)
    }

    func testViaAndHoleChecks() throws {
        var b = Board(version: 20260206)
        b.vias = [
            Via(kind: .through, position: Point(0, 0), size: 0.4, drill: 0.3, endLayers: ["F.Cu", "B.Cu"], spannedLayers: ["F.Cu", "B.Cu"], net: "A"),
            Via(kind: .through, position: Point(0.6, 0), size: 0.6, drill: 0.3, endLayers: ["F.Cu", "B.Cu"], spannedLayers: ["F.Cu", "B.Cu"], net: "A"),
        ]
        let r = try run(b, rules: ["min_via_annular_width": 0.13, "min_hole_to_hole": 0.45], profile: "jlcpcb")
        let ring = r.findings.filter { $0.kind == .viaAnnularRing && $0.suite == .kicad }
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(try XCTUnwrap(ring.first?.actual), 0.05, accuracy: 1e-9)
        // JLCPCB: 0.05 mm is the limit, 0.075 mm recommended -> a warning.
        XCTAssertEqual(r.findings.first { $0.kind == .viaAnnularRing && $0.suite != .kicad }?.severity, .warning)
        let h2h = try XCTUnwrap(r.findings.first { $0.kind == .holeToHole && $0.suite == .kicad })
        XCTAssertEqual(try XCTUnwrap(h2h.actual), 0.3, accuracy: 1e-9)
        // Vias of one net overlap copper but that is not a clearance problem.
        XCTAssertTrue(r.findings.filter { $0.kind == .clearance }.isEmpty)
    }

    func testEdgeClearance() throws {
        var b = Board(version: 20260206)
        b.graphics = [Graphic(kind: .rect, points: [Point(-1, -1), Point(20, 10)], width: 0.05, layer: "Edge.Cuts", filled: false)]
        b.tracks = [track(-0.7, net: "A")]
        let r = try run(b, rules: ["min_copper_edge_clearance": 0.3], profile: "jlcpcb")
        let edge = r.findings.filter { $0.kind == .edgeClearance }
        XCTAssertEqual(edge.count, 1, "0.2 mm meets JLCPCB but not the board's 0.3 mm")
        XCTAssertEqual(try XCTUnwrap(edge.first?.actual), 0.2, accuracy: 1e-9)
    }

    func testSampleBoard() throws {
        let input = BoardParserTests.input
        for id in FabProfiles.bundledIDs {
            let r = DesignChecker(input: input, profile: try FabProfiles.load(id: id)).run()
            XCTAssertEqual(r.findings.filter { $0.kind == .ruleNotChecked }.count, 0, "every custom rule in the sample is understood")
            XCTAssertEqual(Set(r.findings.map(\.id)).count, r.findings.count)
            let silk: Set<CheckKind> = [.silkLineWidth, .textHeight, .textThickness, .silkToPad]
            XCTAssertFalse(r.findings.contains { silk.contains($0.kind) && $0.suite != .kicad && $0.severity == .error },
                           "fab silkscreen limits are warnings")
            for f in r.findings {
                XCTAssertFalse(f.message.isEmpty)
                XCTAssertLessThanOrEqual(f.area.minX, f.area.maxX)
            }
            print("\(id): \(r.count(.error)) errors, \(r.count(.warning)) warnings in \(r.seconds) s")
        }
    }
}

final class KiCadDRCReportTests: XCTestCase {
    func testParse() throws {
        let board = BoardParserTests.input.board
        let track = try XCTUnwrap(board.tracks.first)
        let json = """
        {"$schema": "https://schemas.kicad.org/drc.v1.json", "coordinate_units": "mm", "kicad_version": "10.0.0",
         "source": "THRH_Node.kicad_pcb",
         "violations": [{"type": "clearance", "severity": "error",
            "description": "Clearance violation (netclass 'Default' clearance 0.1500 mm; actual 0.1200 mm)",
            "items": [{"description": "Track [GND] on F.Cu", "pos": {"x": 120.5, "y": 110.25}, "uuid": "\(track.uuid ?? "")"},
                      {"description": "Pad 1 [VCC] of R1 on F.Cu", "pos": {"x": 120.7, "y": 110.3}, "uuid": "nope"}]}],
         "unconnected_items": [{"type": "unconnected_items", "severity": "warning", "description": "Missing connection",
            "items": [{"description": "Pad 2", "pos": {"x": 130, "y": 115}}]}],
         "schematic_parity": []}
        """
        let f = try KiCadDRCReport.findings(from: Data(json.utf8), board: board)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f[0].suite, .kicadDRC)
        XCTAssertEqual(f[0].kind, .drcViolation)
        XCTAssertEqual(f[0].severity, .error)
        XCTAssertEqual(f[0].location, Point(120.5, 110.25))
        XCTAssertEqual(f[0].items, [.track(0)])
        XCTAssertTrue(f[0].message.hasPrefix("Clearance violation"))
        XCTAssertEqual(f[1].kind, .drcUnconnected)
        XCTAssertEqual(f[1].severity, .warning)
        XCTAssertThrowsError(try KiCadDRCReport.findings(from: Data("{\"coordinate_units\": \"mils\"}".utf8), board: board))
    }
}
