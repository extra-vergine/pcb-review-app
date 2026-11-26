import XCTest
@testable import KiCadKit

/// Tests against René's THRH_Node (Roomy v4) board, a real KiCad 10 design.
/// Expected counts were taken independently from the file with a separate script.
final class BoardParserTests: XCTestCase {
    static var fixtures: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }
    static let input: ReviewInput = {
        try! ReviewInput.load(boardAt: fixtures.appendingPathComponent("THRH_Node.kicad_pcb"))
    }()
    var board: Board { Self.input.board }

    func testHeader() {
        XCTAssertEqual(board.version, 20260206)
        XCTAssertEqual(board.generatorVersion, "10.0")
        XCTAssertEqual(board.title, "Roomy - PoE temperature / humidity node")
        XCTAssertEqual(board.revision, "v4")
        XCTAssertEqual(board.thickness, 1.6)
        XCTAssertTrue(Self.input.warnings.isEmpty, "\(Self.input.warnings)")
    }

    func testLayersAndStackup() {
        XCTAssertEqual(board.copperLayers.map(\.name), ["F.Cu", "In1.Cu", "In2.Cu", "B.Cu"])
        XCTAssertEqual(board.layers.first { $0.name == "In1.Cu" }?.userName, "GND")
        XCTAssertEqual(board.stackup.filter { $0.type == "copper" }.count, 4)
        XCTAssertEqual(board.stackup.first { $0.name == "dielectric 2" }?.thickness, 1.065)
    }

    func testItemCounts() {
        XCTAssertEqual(board.footprints.count, 108)
        XCTAssertEqual(board.pads.count, 466)
        XCTAssertEqual(board.tracks.filter { !$0.isArc }.count, 961)
        XCTAssertEqual(board.tracks.filter(\.isArc).count, 0)
        XCTAssertEqual(board.vias.count, 341)
        XCTAssertEqual(board.zones.filter { !$0.isRuleArea }.count, 8)
        XCTAssertEqual(board.zones.filter(\.isRuleArea).count, 2)
        XCTAssertEqual(board.zones.reduce(0) { $0 + $1.filledPolygons.count }, 70)
        XCTAssertEqual(board.nets.count, 156)
        XCTAssertTrue(board.nets.contains("/Ethernet/ETH_TXP"))
        XCTAssertFalse(board.nets.contains(""))
    }

    func testOutline() throws {
        let b = try XCTUnwrap(board.outlineBounds)
        XCTAssertEqual(b.minX, 100); XCTAssertEqual(b.maxX, 200)
        XCTAssertEqual(b.minY, 100); XCTAssertEqual(b.maxY, 140)
        XCTAssertEqual(board.graphics.filter { $0.layer == "Edge.Cuts" }.count, 12)
    }

    func testPadsLandOnTrackEnds() {
        // Track ends sit on pad centres, so this checks the footprint rotation
        // and translation maths, including on the 22 rotated footprints.
        // The opposite rotation sense matches only 391.
        var padsByNet: [String: [Point]] = [:]
        for p in board.pads { if let n = p.net { padsByNet[n, default: []].append(p.position) } }
        var hits = 0
        for t in board.tracks where !t.isArc {
            guard let net = t.net, let pads = padsByNet[net] else { continue }
            for end in [t.start, t.end] where pads.contains(where: { $0.distance(to: end) < 1e-3 }) {
                hits += 1
            }
        }
        XCTAssertEqual(hits, 526)
    }

    func testPadDetails() throws {
        let j1 = try XCTUnwrap(board.footprints.first { $0.reference == "J1" })
        XCTAssertEqual(j1.rotation, -90)
        XCTAssertTrue(j1.libraryID.hasPrefix("Connector_RJ:"))
        let th = try XCTUnwrap(board.pads.first { $0.kind == .thruHole })
        XCTAssertEqual(th.copperLayers, ["F.Cu", "In1.Cu", "In2.Cu", "B.Cu"], "*.Cu expands to all copper layers")
        XCTAssertNotNil(th.drill)
    }

    func testVias() throws {
        let v = try XCTUnwrap(board.vias.first)
        XCTAssertEqual(v.size, 0.6); XCTAssertEqual(v.drill, 0.3)
        XCTAssertEqual(v.annularRing, 0.15, accuracy: 1e-9)
        XCTAssertEqual(v.kind, .through)
        XCTAssertEqual(v.spannedLayers.count, 4)
    }

    func testFootprintTexts() {
        let refs = board.texts.filter { $0.footprintReference == "R24" && $0.text == "R24" }
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.height, 0.8)
        XCTAssertEqual(refs.first?.layer, "F.SilkS")
    }
}

final class ProjectTests: XCTestCase {
    var project: Project { BoardParserTests.input.project! }

    func testRules() {
        XCTAssertEqual(project.rule("min_clearance"), 0.15)
        XCTAssertEqual(project.rule("min_track_width"), 0.15)
        XCTAssertEqual(project.rule("min_hole_to_hole"), 0.45)
        XCTAssertEqual(project.netClasses.map(\.name).sorted(), ["Default", "ETH_DIFF", "POWER", "PRIMARY"])
        XCTAssertEqual(project.netClass(named: "ETH_DIFF")?.trackWidth, 0.25)
    }

    func testNetClassResolution() {
        XCTAssertEqual(project.resolveNetClass(for: "GND").effective, "POWER")
        XCTAssertEqual(project.resolveNetClass(for: "VPOE").effective, "PRIMARY")
        XCTAssertEqual(project.resolveNetClass(for: "POE_VSS").effective, "PRIMARY")
        // Patterns are matched against the full hierarchical name, so the bare
        // patterns in this project do not reach sheet-local nets.
        XCTAssertEqual(project.resolveNetClass(for: "/Ethernet/ETH_TXP").effective, "Default")
        XCTAssertEqual(project.resolveNetClass(for: "/Power/PRI_SW").effective, "Default")
    }

    func testPatternMatching() {
        XCTAssertTrue(NetPattern.matches(pattern: "POE_*", name: "POE_VSS"))
        XCTAssertTrue(NetPattern.matches(pattern: "*/ETH_TX?", name: "/Ethernet/ETH_TXP"))
        XCTAssertTrue(NetPattern.matches(pattern: "/Power/P.*", name: "/Power/PRI_SW"))
        XCTAssertFalse(NetPattern.matches(pattern: "ETH_TXP", name: "/Ethernet/ETH_TXP"))
        XCTAssertFalse(NetPattern.matches(pattern: "VCAP*", name: "/Microcontroller/VCAP1"))
    }
}

final class CustomRulesTests: XCTestCase {
    func testParse() throws {
        let rules = try XCTUnwrap(BoardParserTests.input.customRules)
        XCTAssertEqual(rules.version, 1)
        XCTAssertEqual(rules.rules.map(\.name),
                       ["PoE isolation", "JLC min hole", "JLC annular", "JLC edge", "JLC silk", "Diff pair to pour"])
        let iso = rules.rules[0]
        XCTAssertEqual(iso.constraints.first?.type, "clearance")
        XCTAssertEqual(iso.constraints.first?.min, 1.9)
        XCTAssertTrue(iso.condition?.contains("VPOE") ?? false)
        XCTAssertEqual(rules.rules[4].layer, "?.Silkscreen")
        XCTAssertEqual(rules.rules[4].constraints.first?.min, 0.8)
    }

    func testUnits() {
        XCTAssertEqual(Units.parseLength("1.9mm"), 1.9)
        XCTAssertEqual(Units.parseLength("10mil")!, 0.254, accuracy: 1e-12)
        XCTAssertEqual(Units.parseLength("0.2"), 0.2)
    }

    func testCommentsAndStrings() throws {
        let r = try CustomRulesParser.parse("""
        (version 1)
        # a comment with (parens) and "quotes"
        (rule "x" (condition "A.NetName == '#1'") (constraint track_width (min 0.2mm) (max 1mm)))
        """)
        XCTAssertEqual(r.rules.first?.condition, "A.NetName == '#1'")
        XCTAssertEqual(r.rules.first?.constraints.first?.max, 1)
    }
}

final class SExprTests: XCTestCase {
    func testBasics() throws {
        let n = try SExprParser.parse(#"(a (b 1 2) "x \"y\"" sym)"#)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].head, "a")
        XCTAssertEqual(n[0].child("b")?.double(at: 2), 2)
        XCTAssertEqual(n[0].items[2], .string(#"x "y""#))
        XCTAssertThrowsError(try SExprParser.parse("(a (b)"))
    }
}
