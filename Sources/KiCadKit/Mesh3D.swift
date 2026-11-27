import Foundation

/// A small triangle mesh for 3D export. Coordinates are glTF style: metres, Y up.
public struct Mesh3D: Sendable {
    public struct Primitive: Sendable {
        public var positions: [Float] = []   // x, y, z
        public var normals: [Float] = []     // x, y, z
        public var uvs: [Float] = []         // u, v (v down, top-left origin)
        public var indices: [UInt32] = []
        public var material: Int

        public var vertexCount: Int { positions.count / 3 }

        mutating func addVertex(_ p: (Float, Float, Float), normal n: (Float, Float, Float), uv: (Float, Float)) -> UInt32 {
            positions += [p.0, p.1, p.2]
            normals += [n.0, n.1, n.2]
            uvs += [uv.0, uv.1]
            return UInt32(vertexCount - 1)
        }
    }

    public struct Material: Sendable {
        public var name: String
        public var baseColor: RGBA
        /// Index into the exporter's image list, for a textured face.
        public var image: Int?
        public var roughness: Double = 0.8
        public var metallic: Double = 0
    }

    public var name: String
    public var primitives: [Primitive]
    public var materials: [Material]
}

public enum BoardMesh {
    /// Indices of the materials `make` uses.
    public static let topMaterial = 0, bottomMaterial = 1, edgeMaterial = 2

    /// The board as a slab: the outline extruded to the board thickness.
    /// The top face uses image 0 and the bottom face image 1, both mapped over
    /// `textureBounds` (top-left of the image at minX, minY).
    public static func make(board: Board, textureBounds: Rect) -> Mesh3D? {
        guard let outline = board.outlinePolygon, outline.count >= 3 else { return nil }
        let tris = Polygon.triangulate(outline)
        guard !tris.isEmpty else { return nil }

        let t = Float((board.thickness ?? 1.6) / 1000)
        let cx = textureBounds.minX + textureBounds.width / 2, cy = textureBounds.minY + textureBounds.height / 2
        func X(_ p: Point) -> Float { Float((p.x - cx) / 1000) }
        func Z(_ p: Point) -> Float { Float((p.y - cy) / 1000) }
        func uv(_ p: Point) -> (Float, Float) {
            (Float((p.x - textureBounds.minX) / textureBounds.width), Float((p.y - textureBounds.minY) / textureBounds.height))
        }

        var top = Mesh3D.Primitive(material: topMaterial)
        var bottom = Mesh3D.Primitive(material: bottomMaterial)
        var edge = Mesh3D.Primitive(material: edgeMaterial)

        // Faces: make every triangle face its normal (+Y on top, -Y below).
        for k in stride(from: 0, to: tris.count, by: 3) {
            let a = outline[tris[k]], b = outline[tris[k + 1]], c = outline[tris[k + 2]]
            // Y component of (b - a) × (c - a) in (X, Y, Z) space with Y = 0.
            let ny = (Z(b) - Z(a)) * (X(c) - X(a)) - (X(b) - X(a)) * (Z(c) - Z(a))
            let upOrder = ny > 0 ? [a, b, c] : [a, c, b]
            for p in upOrder {
                top.indices.append(top.addVertex((X(p), t, Z(p)), normal: (0, 1, 0), uv: uv(p)))
            }
            for p in upOrder.reversed() {
                bottom.indices.append(bottom.addVertex((X(p), 0, Z(p)), normal: (0, -1, 0), uv: uv(p)))
            }
        }

        // Edge walls, one flat quad per outline segment, facing outwards.
        let ccw = Polygon.signedArea(outline) > 0
        for i in 0..<outline.count {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let dx = X(b) - X(a), dz = Z(b) - Z(a)
            let len = (dx * dx + dz * dz).squareRoot()
            guard len > 0 else { continue }
            // Outward normal in the X/Z plane: board-frame CCW (Y down) means the outside is on the left.
            var nx = dz / len, nz = -dx / len
            if !ccw { nx = -nx; nz = -nz }
            let n = (nx, Float(0), nz)
            let v0 = edge.addVertex((X(a), 0, Z(a)), normal: n, uv: (0, 1))
            let v1 = edge.addVertex((X(b), 0, Z(b)), normal: n, uv: (1, 1))
            let v2 = edge.addVertex((X(b), t, Z(b)), normal: n, uv: (1, 0))
            let v3 = edge.addVertex((X(a), t, Z(a)), normal: n, uv: (0, 0))
            // Wind so the face points along n.
            let ex = (X(b) - X(a), Float(0), Z(b) - Z(a)), ey = (Float(0), t, Float(0))
            let cross = (ex.1 * ey.2 - ex.2 * ey.1, ex.2 * ey.0 - ex.0 * ey.2, ex.0 * ey.1 - ex.1 * ey.0)
            if cross.0 * n.0 + cross.2 * n.2 >= 0 {
                edge.indices += [v0, v1, v2, v0, v2, v3]
            } else {
                edge.indices += [v0, v2, v1, v0, v3, v2]
            }
        }

        let materials = [
            Mesh3D.Material(name: "Top", baseColor: RGBA(1, 1, 1), image: 0),
            Mesh3D.Material(name: "Bottom", baseColor: RGBA(1, 1, 1), image: 1),
            Mesh3D.Material(name: "Edge", baseColor: RGBA(0.62, 0.58, 0.42)),
        ]
        return Mesh3D(name: board.title ?? "Board", primitives: [top, bottom, edge], materials: materials)
    }
}

/// Writes a mesh as binary glTF 2.0 (`.glb`) with embedded PNG textures.
public enum GLBWriter {
    public static func write(_ mesh: Mesh3D, images: [Data]) throws -> Data {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        func align() { while bin.count % 4 != 0 { bin.append(0) } }
        func addView(_ data: Data, target: Int?) -> Int {
            align()
            var v: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": data.count]
            if let target { v["target"] = target }
            bin.append(data)
            bufferViews.append(v)
            return bufferViews.count - 1
        }
        func floats(_ a: [Float]) -> Data { a.withUnsafeBufferPointer { Data(buffer: $0) } }
        func uints(_ a: [UInt32]) -> Data { a.withUnsafeBufferPointer { Data(buffer: $0) } }

        var primitives: [[String: Any]] = []
        for p in mesh.primitives where !p.indices.isEmpty {
            let n = p.vertexCount
            var mins: [Float] = [.infinity, .infinity, .infinity], maxs: [Float] = [-.infinity, -.infinity, -.infinity]
            for i in 0..<n { for k in 0..<3 { mins[k] = min(mins[k], p.positions[i * 3 + k]); maxs[k] = max(maxs[k], p.positions[i * 3 + k]) } }
            let pv = addView(floats(p.positions), target: 34962)
            accessors.append(["bufferView": pv, "componentType": 5126, "count": n, "type": "VEC3",
                              "min": mins.map(Double.init), "max": maxs.map(Double.init)])
            let pos = accessors.count - 1
            let nv = addView(floats(p.normals), target: 34962)
            accessors.append(["bufferView": nv, "componentType": 5126, "count": n, "type": "VEC3"])
            let nor = accessors.count - 1
            let tv = addView(floats(p.uvs), target: 34962)
            accessors.append(["bufferView": tv, "componentType": 5126, "count": n, "type": "VEC2"])
            let tex = accessors.count - 1
            let iv = addView(uints(p.indices), target: 34963)
            accessors.append(["bufferView": iv, "componentType": 5125, "count": p.indices.count, "type": "SCALAR"])
            let ind = accessors.count - 1
            primitives.append(["attributes": ["POSITION": pos, "NORMAL": nor, "TEXCOORD_0": tex],
                               "indices": ind, "material": p.material, "mode": 4])
        }

        var jsonImages: [[String: Any]] = []
        for img in images {
            let v = addView(img, target: nil)
            jsonImages.append(["bufferView": v, "mimeType": "image/png"])
        }
        align()

        let materials: [[String: Any]] = mesh.materials.map { m in
            var pbr: [String: Any] = [
                "baseColorFactor": [m.baseColor.r, m.baseColor.g, m.baseColor.b, m.baseColor.a],
                "metallicFactor": m.metallic, "roughnessFactor": m.roughness,
            ]
            if let i = m.image, i < images.count { pbr["baseColorTexture"] = ["index": i] }
            return ["name": m.name, "pbrMetallicRoughness": pbr, "doubleSided": false]
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "PCB Review"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": mesh.name]],
            "meshes": [["name": mesh.name, "primitives": primitives]],
            "materials": materials,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
        ]
        if !jsonImages.isEmpty {
            json["images"] = jsonImages
            json["samplers"] = [["magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071]]
            json["textures"] = (0..<jsonImages.count).map { ["source": $0, "sampler": 0] }
        }

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        u32(0x46546C67)                      // "glTF"
        u32(2)
        u32(UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        u32(UInt32(jsonData.count)); u32(0x4E4F534A) // "JSON"
        out.append(jsonData)
        u32(UInt32(bin.count)); u32(0x004E4942)      // "BIN\0"
        out.append(bin)
        return out
    }
}
