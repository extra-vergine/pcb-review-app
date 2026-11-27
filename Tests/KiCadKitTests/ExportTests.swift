import XCTest
@testable import KiCadKit

final class ExportTests: XCTestCase {
    var board: Board { BoardParserTests.input.board }
    var options: ExportOptions {
        ExportOptions(layers: ["B.Cu", "In2.Cu", "In1.Cu", "F.Cu", "F.SilkS", "Edge.Cuts"],
                      colors: ["F.Cu": RGBA(0.85, 0.27, 0.25)])
    }

    func testOutlinePolygon() throws {
        let outline = try XCTUnwrap(board.outlinePolygon)
        // 100 x 40 mm with four 4 mm corner radii.
        let expected = 100.0 * 40 - 4 * (16 - Double.pi * 4)
        XCTAssertEqual(abs(Polygon.signedArea(outline)), expected, accuracy: 0.5)
    }

    func testTriangulationCoversThePolygon() throws {
        let outline = try XCTUnwrap(board.outlinePolygon)
        let tris = Polygon.triangulate(outline)
        XCTAssertEqual(tris.count, (outline.count - 2) * 3)
        var sum = 0.0
        for k in stride(from: 0, to: tris.count, by: 3) {
            sum += abs(Polygon.signedArea([outline[tris[k]], outline[tris[k + 1]], outline[tris[k + 2]]]))
        }
        XCTAssertEqual(sum, abs(Polygon.signedArea(outline)), accuracy: 1e-6)

        // A concave L shape.
        let l = [Point(0, 0), Point(2, 0), Point(2, 1), Point(1, 1), Point(1, 2), Point(0, 2)]
        XCTAssertEqual(Polygon.triangulate(l).count, 12)
    }

    func testMeshFacesPointTheRightWay() throws {
        let b = try XCTUnwrap(board.outlineBounds)
        let mesh = try XCTUnwrap(BoardMesh.make(board: board, textureBounds: b))
        XCTAssertEqual(mesh.primitives.count, 3)
        let top = mesh.primitives[BoardMesh.topMaterial]
        // Every top triangle's geometric normal points up (+Y).
        for k in stride(from: 0, to: top.indices.count, by: 3) {
            let p = (0..<3).map { j -> (Float, Float, Float) in
                let i = Int(top.indices[k + j]) * 3
                return (top.positions[i], top.positions[i + 1], top.positions[i + 2])
            }
            let u = (p[1].0 - p[0].0, p[1].2 - p[0].2), v = (p[2].0 - p[0].0, p[2].2 - p[0].2)
            XCTAssertGreaterThan(u.1 * v.0 - u.0 * v.1, -1e-12)
        }
        XCTAssertEqual(top.uvs.min()!, 0, accuracy: 1e-4)
        XCTAssertEqual(top.uvs.max()!, 1, accuracy: 1e-4)
    }

    func testGLB() throws {
        let b = try XCTUnwrap(board.outlineBounds)
        let mesh = try XCTUnwrap(BoardMesh.make(board: board, textureBounds: b))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let glb = try GLBWriter.write(mesh, images: [png, png])
        func u32(_ o: Int) -> UInt32 { glb[o..<o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        XCTAssertEqual(u32(0), 0x46546C67)
        XCTAssertEqual(u32(4), 2)
        XCTAssertEqual(Int(u32(8)), glb.count)
        let jsonLength = Int(u32(12))
        XCTAssertEqual(jsonLength % 4, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: glb[20..<20 + jsonLength]) as? [String: Any])
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        XCTAssertEqual((meshes[0]["primitives"] as? [Any])?.count, 3)
        XCTAssertEqual((json["images"] as? [Any])?.count, 2)
    }

    func testSVG() {
        let svg = SVGExporter.svg(board: board, options: options)
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("width=\"106.0000mm\""))
        XCTAssertTrue(svg.contains("<g id=\"F.Cu\" fill=\"#d94540\""))
        XCTAssertTrue(svg.contains("<g id=\"holes\""))
        XCTAssertTrue(svg.hasSuffix("</svg>\n"))
    }

    func testHPGL() {
        let plt = HPGLExporter.hpgl(board: board, options: options)
        XCTAssertTrue(plt.hasPrefix("IN;"))
        XCTAssertTrue(plt.contains("CO \"F.Cu\";"))
        XCTAssertTrue(plt.contains("CI"))
        XCTAssertTrue(plt.hasSuffix("PU;SP0;\n"))
        // All coordinates are inside the 106 x 46 mm plot area (40 units per mm).
        let numbers = plt.split(whereSeparator: { !"0123456789-".contains($0) }).compactMap { Int($0) }
        XCTAssertLessThanOrEqual(numbers.max() ?? 0, 106 * 40)
        XCTAssertGreaterThanOrEqual(numbers.min() ?? 0, 0)
    }
}
