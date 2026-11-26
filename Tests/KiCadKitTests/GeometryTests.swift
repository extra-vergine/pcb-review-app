import XCTest
@testable import KiCadKit

final class GeometryTests: XCTestCase {
    var board: Board { BoardParserTests.input.board }

    func testCircleThroughThreePoints() throws {
        let c = try XCTUnwrap(Shapes.circle(through: Point(1, 0), Point(0, 1), Point(-1, 0)))
        XCTAssertEqual(c.center.x, 0, accuracy: 1e-12)
        XCTAssertEqual(c.center.y, 0, accuracy: 1e-12)
        XCTAssertEqual(c.radius, 1, accuracy: 1e-12)
        XCTAssertNil(Shapes.circle(through: Point(0, 0), Point(1, 1), Point(2, 2)))
    }

    func testArcPointsFollowTheArcInBothDirections() {
        // The board's top-left corner arc: centre (104, 104), radius 4.
        let s = Point(100, 104), m = Point(101.1716, 101.1716), e = Point(104, 100)
        for (a, b) in [(s, e), (e, s)] {
            let pts = Shapes.arcPoints(start: a, mid: m, end: b)
            XCTAssertGreaterThan(pts.count, 4)
            XCTAssertEqual(pts.first!.distance(to: a), 0, accuracy: 1e-9)
            XCTAssertEqual(pts.last!.distance(to: b), 0, accuracy: 1e-3)
            for p in pts {
                XCTAssertEqual(p.distance(to: Point(104, 104)), 4, accuracy: 1e-3)
                // The quarter arc stays in the top-left quadrant of its centre.
                XCTAssertLessThanOrEqual(p.x, 104 + 1e-6)
                XCTAssertLessThanOrEqual(p.y, 104 + 1e-6)
            }
        }
    }

    func testSegmentDistanceAndPolygon() {
        XCTAssertEqual(Shapes.distance(from: Point(0, 1), toSegment: Point(-1, 0), Point(1, 0)), 1)
        XCTAssertEqual(Shapes.distance(from: Point(3, 0), toSegment: Point(-1, 0), Point(1, 0)), 2)
        let square = [Point(0, 0), Point(2, 0), Point(2, 2), Point(0, 2)]
        XCTAssertTrue(Shapes.contains(square, Point(1, 1)))
        XCTAssertFalse(Shapes.contains(square, Point(3, 1)))
    }

    func testPadOutline() throws {
        let r24 = try XCTUnwrap(board.footprints.first { $0.reference == "R24" })
        let pad = try XCTUnwrap(r24.pads.first { $0.number == "1" })
        XCTAssertEqual(pad.position.x, 124.175, accuracy: 1e-9)
        XCTAssertEqual(pad.position.y, 109, accuracy: 1e-9)
        XCTAssertTrue(Shapes.contains(pad.outline, pad.position))
        XCTAssertTrue(Shapes.contains(pad.outline, pad.position + Point(0.35, 0)))   // width 0.8
        XCTAssertFalse(Shapes.contains(pad.outline, pad.position + Point(0.45, 0)))
        // R24 is not rotated, so the outline keeps the pad size.
        let bounds = try XCTUnwrap(Rect.enclosing(pad.outline))
        XCTAssertEqual(bounds.width, 0.8, accuracy: 1e-6)
        XCTAssertEqual(bounds.height, 0.95, accuracy: 1e-6)
    }

    func testHitTest() throws {
        let all = Set(board.layers.map(\.name))
        let r24 = try XCTUnwrap(board.footprints.firstIndex { $0.reference == "R24" })
        XCTAssertEqual(board.hitTest(Point(124.175, 109), visibleLayers: all), .pad(footprint: r24, pad: 0))

        let via = board.vias[0]
        XCTAssertEqual(board.hitTest(via.position, visibleLayers: all), .via(0))

        // The middle of a long track hits that track or something on the same net.
        let i = try XCTUnwrap(board.tracks.indices.max { board.tracks[$0].start.distance(to: board.tracks[$0].end) < board.tracks[$1].start.distance(to: board.tracks[$1].end) })
        let t = board.tracks[i]
        let mid = Point((t.start.x + t.end.x) / 2, (t.start.y + t.end.y) / 2)
        let hit = try XCTUnwrap(board.hitTest(mid, visibleLayers: [t.layer]))
        XCTAssertEqual(board.net(of: hit), t.net)

        // Nothing is hit off the board.
        XCTAssertNil(board.hitTest(Point(50, 50), visibleLayers: all))
        // Hidden layers are skipped.
        XCTAssertNil(board.hitTest(via.position, visibleLayers: []))
    }
}
