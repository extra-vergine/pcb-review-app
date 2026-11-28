import Foundation

/// A triangle mesh with one colour, from a 3D model file.
public struct ModelPart: Sendable {
    public var color: RGBA
    /// x, y, z per vertex, in mm in the model's own frame (x right, y up, z out of the board).
    public var positions: [Float]
    public var indices: [UInt32]
}

/// Reads the VRML 2.0 (`.wrl`) files that KiCad's 3D model library ships next to
/// its STEP files. Handles `Shape`, `Appearance`, `Material`, `IndexedFaceSet`,
/// `Coordinate`, `Transform` and `Group`, with `DEF` / `USE`. KiCad's VRML unit
/// is 0.1 inch, so coordinates are scaled to mm.
public enum VRMLReader {
    public static let kicadUnitMM: Float = 2.54

    public struct ParseError: Error, CustomStringConvertible { public var description: String }

    public static func read(contentsOf url: URL, unit: Float = kicadUnitMM) throws -> [ModelPart] {
        let data = try Data(contentsOf: url)
        return try parse(String(decoding: data, as: UTF8.self), unit: unit)
    }

    public static func parse(_ text: String, unit: Float = kicadUnitMM) throws -> [ModelPart] {
        var p = Parser(tokens: tokenize(text))
        var roots: [Node] = []
        while !p.atEnd {
            if let n = try p.parseNodeOrNil() { roots.append(n) } else { p.pos += 1 }
        }
        var out: [ModelPart] = []
        let identity = Affine.identity.scaled(unit)
        for r in roots { collect(r, transform: identity, defs: p.defs, into: &out) }
        return out
    }

    // MARK: Tree

    final class Node {
        var type: String
        var fields: [String: Value] = [:]
        init(type: String) { self.type = type }
    }

    enum Value {
        case numbers([Float])
        case node(Node)
        case nodes([Node])
        case other
    }

    /// A 3x4 affine transform.
    struct Affine {
        var m: [Float] // row-major 3x3
        var t: (Float, Float, Float)
        static let identity = Affine(m: [1, 0, 0, 0, 1, 0, 0, 0, 1], t: (0, 0, 0))
        func scaled(_ s: Float) -> Affine { Affine(m: m.map { $0 * s }, t: (t.0 * s, t.1 * s, t.2 * s)) }
        func apply(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
            (m[0] * x + m[1] * y + m[2] * z + t.0, m[3] * x + m[4] * y + m[5] * z + t.1, m[6] * x + m[7] * y + m[8] * z + t.2)
        }
        /// self ∘ other (other applied first).
        func then(_ other: Affine) -> Affine {
            var r = [Float](repeating: 0, count: 9)
            for i in 0..<3 {
                for j in 0..<3 {
                    var sum: Float = 0
                    for n in 0..<3 { sum += m[i * 3 + n] * other.m[n * 3 + j] }
                    r[i * 3 + j] = sum
                }
            }
            let (tx, ty, tz) = apply(other.t.0, other.t.1, other.t.2)
            return Affine(m: r, t: (tx, ty, tz))
        }
    }

    static func collect(_ node: Node, transform: Affine, defs: [String: Node], into out: inout [ModelPart]) {
        switch node.type {
        case "Transform", "Group":
            var t = transform
            if node.type == "Transform" {
                var local = Affine.identity
                if case .numbers(let s)? = node.fields["scale"], s.count == 3 {
                    local = Affine(m: [s[0], 0, 0, 0, s[1], 0, 0, 0, s[2]], t: (0, 0, 0))
                }
                if case .numbers(let r)? = node.fields["rotation"], r.count == 4 {
                    local = rotation(axis: (r[0], r[1], r[2]), angle: r[3]).then(local)
                }
                if case .numbers(let tr)? = node.fields["translation"], tr.count == 3 {
                    local.t = (local.t.0 + tr[0], local.t.1 + tr[1], local.t.2 + tr[2])
                }
                t = transform.then(local)
            }
            for child in children(node) { collect(child, transform: t, defs: defs, into: &out) }
        case "Shape":
            guard case .node(let geo)? = node.fields["geometry"], geo.type == "IndexedFaceSet",
                  case .node(let coord)? = geo.fields["coord"], case .numbers(let pts)? = coord.fields["point"],
                  case .numbers(let idx)? = geo.fields["coordIndex"] else { return }
            var color = RGBA(0.6, 0.6, 0.6)
            if case .node(let app)? = node.fields["appearance"], case .node(let mat)? = app.fields["material"],
               case .numbers(let c)? = mat.fields["diffuseColor"], c.count == 3 {
                var alpha = 1.0
                if case .numbers(let tr)? = mat.fields["transparency"], let a = tr.first { alpha = 1 - Double(a) }
                color = RGBA(Double(c[0]), Double(c[1]), Double(c[2]), alpha)
            }
            var positions: [Float] = []
            positions.reserveCapacity(pts.count)
            for k in stride(from: 0, to: pts.count - 2, by: 3) {
                let (x, y, z) = transform.apply(pts[k], pts[k + 1], pts[k + 2])
                positions += [x, y, z]
            }
            let n = positions.count / 3
            var indices: [UInt32] = []
            var face: [Int] = []
            func flush() {
                if face.count >= 3, face.allSatisfy({ $0 >= 0 && $0 < n }) {
                    for i in 1..<(face.count - 1) { indices += [UInt32(face[0]), UInt32(face[i]), UInt32(face[i + 1])] }
                }
                face.removeAll()
            }
            for v in idx { if v < 0 { flush() } else { face.append(Int(v)) } }
            flush()
            if !indices.isEmpty { out.append(ModelPart(color: color, positions: positions, indices: indices)) }
        default:
            for child in children(node) { collect(child, transform: transform, defs: defs, into: &out) }
        }
    }

    static func children(_ node: Node) -> [Node] {
        switch node.fields["children"] {
        case .nodes(let list)?: return list
        case .node(let n)?: return [n]
        default: return []
        }
    }

    static func rotation(axis: (Float, Float, Float), angle a: Float) -> Affine {
        let len = (axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2).squareRoot()
        guard len > 0 else { return .identity }
        let x = axis.0 / len, y = axis.1 / len, z = axis.2 / len
        let c = cos(a), s = sin(a), C = 1 - c
        return Affine(m: [x * x * C + c, x * y * C - z * s, x * z * C + y * s,
                          y * x * C + z * s, y * y * C + c, y * z * C - x * s,
                          z * x * C - y * s, z * y * C + x * s, z * z * C + c], t: (0, 0, 0))
    }

    // MARK: Tokens and parsing

    static func tokenize(_ s: String) -> [Substring] {
        var out: [Substring] = []
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "#" {
                while i < s.endIndex, s[i] != "\n" { i = s.index(after: i) }
                continue
            }
            if ch.isWhitespace || ch == "," { i = s.index(after: i); continue }
            if "{}[]".contains(ch) { out.append(s[i...i]); i = s.index(after: i); continue }
            if ch == "\"" {
                var j = s.index(after: i)
                while j < s.endIndex, s[j] != "\"" { j = s.index(after: j) }
                let end = j < s.endIndex ? s.index(after: j) : j
                out.append(s[i..<end]); i = end
                continue
            }
            var j = i
            while j < s.endIndex, !s[j].isWhitespace, !"{}[],#\"".contains(s[j]) { j = s.index(after: j) }
            out.append(s[i..<j]); i = j
        }
        return out
    }

    struct Parser {
        var tokens: [Substring]
        var pos = 0
        var defs: [String: Node] = [:]
        var atEnd: Bool { pos >= tokens.count }
        func peek(_ k: Int = 0) -> Substring? { pos + k < tokens.count ? tokens[pos + k] : nil }

        static func isNumber(_ t: Substring) -> Bool {
            guard let c = t.first else { return false }
            return c.isNumber || c == "-" || c == "+" || c == "."
        }

        /// A node at the current position, or nil (without moving) if there is none.
        mutating func parseNodeOrNil() throws -> Node? {
            guard let t = peek() else { return nil }
            if t == "USE", let name = peek(1) {
                pos += 2
                return defs[String(name)] ?? Node(type: "Unknown")
            }
            if t == "DEF", let name = peek(1) {
                pos += 2
                guard let n = try parseNodeOrNil() else { return nil }
                defs[String(name)] = n
                return n
            }
            guard peek(1) == "{", let first = t.first, first.isLetter else { return nil }
            pos += 2
            let node = Node(type: String(t))
            while let f = peek(), f != "}" {
                pos += 1
                node.fields[String(f)] = try parseValue()
            }
            pos += 1
            return node
        }

        mutating func parseValue() throws -> Value {
            guard let t = peek() else { return .other }
            if t == "[" {
                pos += 1
                var numbers: [Float] = []
                var nodes: [Node] = []
                while let x = peek(), x != "]" {
                    if Self.isNumber(x) { numbers.append(Float(String(x)) ?? 0); pos += 1 }
                    else if let n = try parseNodeOrNil() { nodes.append(n) }
                    else { pos += 1 }
                }
                pos += 1
                return nodes.isEmpty ? .numbers(numbers) : .nodes(nodes)
            }
            if let n = try parseNodeOrNil() { return .node(n) }
            var numbers: [Float] = []
            while let x = peek(), Self.isNumber(x) { numbers.append(Float(String(x)) ?? 0); pos += 1 }
            if !numbers.isEmpty { return .numbers(numbers) }
            pos += 1 // TRUE, FALSE, a string or an unknown word
            return .other
        }
    }
}

/// Finds the files behind KiCad's 3D model paths.
public enum ModelLibrary {
    /// Folders where KiCad installs its 3D models on macOS, newest first.
    public static var defaultRoots: [String] {
        var roots: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("KICAD") && k.hasSuffix("3DMODEL_DIR") { roots.append(v) }
        roots += [
            "/Applications/KiCad/KiCad.app/Contents/SharedSupport/3dmodels",
            "/Applications/KiCad.app/Contents/SharedSupport/3dmodels",
            NSHomeDirectory() + "/Library/Application Support/kicad/3dmodels",
        ]
        return roots
    }

    /// KiCad's path variables set in its preferences (Preferences › Configure Paths),
    /// from the newest `kicad_common.json`, e.g. `MY_3D_MODELS` → `/Users/me/3d`.
    public static var userPathVariables: [String: String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var dirs = [home + "/Library/Preferences/kicad", home + "/.config/kicad"]
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] { dirs.append(x + "/kicad") }
        var best: (version: Double, url: URL)?
        for d in dirs {
            for v in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
                let url = URL(fileURLWithPath: d).appendingPathComponent(v).appendingPathComponent("kicad_common.json")
                guard fm.fileExists(atPath: url.path) else { continue }
                let n = Double(v) ?? 0
                if best == nil || n > best!.version { best = (n, url) }
            }
        }
        guard let url = best?.url, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["environment"] as? [String: Any],
              let vars = env["vars"] as? [String: String] else { return [:] }
        return vars
    }

    /// Fills in `${NAME}` and `$(NAME)` from `variables`, leaving unknown names in place.
    public static func expand(_ path: String, _ variables: [String: String]) -> String {
        var out = path
        for (open, close) in [("${", "}"), ("$(", ")")] {
            while let a = out.range(of: open), let b = out[a.upperBound...].range(of: close) {
                let name = String(out[a.upperBound..<b.lowerBound])
                guard let value = variables[name] else { break }
                out.replaceSubrange(a.lowerBound..<b.upperBound, with: value)
            }
        }
        return out
    }

    /// The model path as a full file path, with every variable filled in, or nil if one is unknown.
    public static func expandedPath(_ path: String, boardFolder: URL, variables: [String: String]) -> String? {
        var vars = ProcessInfo.processInfo.environment
        for (k, v) in variables { vars[k] = v }
        vars["KIPRJMOD"] = boardFolder.path
        var expanded = expand(path.trimmingCharacters(in: .whitespaces), vars)
        if expanded.hasPrefix("~") { expanded = (expanded as NSString).expandingTildeInPath }
        guard !expanded.contains("${"), !expanded.contains("$(") else { return nil }
        return expanded.hasPrefix("/") ? expanded : boardFolder.appendingPathComponent(expanded).path
    }

    /// The VRML file for a model path, or nil. The path may use `${KIPRJMOD}`, KiCad's
    /// library variables, the user's own path variables or environment variables, or be
    /// absolute or relative to the board. A `.wrl` next to a `.step` is used, as KiCad's
    /// libraries ship both. STEP-only models are left to `ModelConversion`.
    public static func resolve(_ path: String, boardFolder: URL, roots: [String] = defaultRoots,
                               variables: [String: String]? = nil) -> URL? {
        var candidates: [String] = []
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: #"\$\{KICAD\d*_3DMODEL_DIR\}"#, options: .regularExpression), r.lowerBound == trimmed.startIndex {
            let rest = String(trimmed[r.upperBound...])
            candidates = roots.map { $0 + rest }
        }
        if let full = expandedPath(trimmed, boardFolder: boardFolder, variables: variables ?? userPathVariables) {
            candidates.append(full)
        }
        let fm = FileManager.default
        for c in candidates {
            let ext = (c as NSString).pathExtension.lowercased()
            if ext == "wrl" || ext == "vrml", fm.fileExists(atPath: c) { return URL(fileURLWithPath: c) }
            let base = (c as NSString).deletingPathExtension
            for e in ["wrl", "WRL", "vrml"] where fm.fileExists(atPath: base + "." + e) {
                return URL(fileURLWithPath: base + "." + e)
            }
        }
        return nil
    }
}

/// Turns a board's STEP models into VRML with `kicad-cli pcb export vrml`, which writes
/// each model it uses into a folder. KiCad reads STEP files itself, so this finds
/// every model KiCad's own 3D viewer finds, including ones in the project folder.
public enum ModelConversion {
    /// Where the converted models for this version of the board file go.
    public static func cacheFolder(for board: URL) -> URL {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let attrs = try? fm.attributesOfItem(atPath: board.path)
        let stamp = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let name = board.deletingPathExtension().lastPathComponent
        return caches.appendingPathComponent("PCBReview/models/\(name)-\(stamp)-\(size)", isDirectory: true)
    }

    public static func arguments(board: URL, folder: URL) -> [String] {
        ["pcb", "export", "vrml", "--units", "mm",
         "--models-dir", folder.appendingPathComponent("models").path,
         "--output", folder.appendingPathComponent("board.wrl").path, board.path]
    }

    /// Runs the conversion once per board version. Returns the `.wrl` files by
    /// lower-cased file name without extension, and kicad-cli's output if it failed.
    /// With `force`, converts again even if this board version was converted before
    /// (for models added to the project since).
    public static func convert(cli: String, board: URL, force: Bool = false) -> (models: [String: URL], log: String?) {
        let folder = cacheFolder(for: board)
        let fm = FileManager.default
        var log: String?
        if force { try? fm.removeItem(at: folder) }
        if !fm.fileExists(atPath: folder.appendingPathComponent("board.wrl").path) {
            try? fm.createDirectory(at: folder.appendingPathComponent("models"), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments(board: board, folder: folder)
            process.currentDirectoryURL = board.deletingLastPathComponent()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    log = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    try? fm.removeItem(at: folder.appendingPathComponent("board.wrl"))
                }
            } catch {
                log = error.localizedDescription
            }
        }
        return (index(folder), log)
    }

    /// Every `.wrl` under `folder` except the board itself.
    public static func index(_ folder: URL) -> [String: URL] {
        var out: [String: URL] = [:]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in e where url.pathExtension.lowercased() == "wrl" && url.lastPathComponent != "board.wrl" {
            out[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }
        return out
    }

    /// The key a model path has in `index`: its file name without extension, lower-cased.
    public static func key(for modelPath: String) -> String {
        let name = modelPath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? modelPath
        return (name as NSString).deletingPathExtension.lowercased()
    }

    /// The unit (mm per file unit) that makes models match their footprints best,
    /// from the ratios of raw model size to footprint body size.
    public static func bestUnit(ratios: [Double]) -> Float {
        let r = ratios.filter { $0 > 0 && $0.isFinite }.sorted()
        guard !r.isEmpty else { return VRMLReader.kicadUnitMM }
        let median = r[r.count / 2]
        let units: [Double] = [2.54, 1, 25.4, 0.1, 1000]
        let best = units.min { abs(log($0 * median)) < abs(log($1 * median)) } ?? 2.54
        return Float(best)
    }
}
