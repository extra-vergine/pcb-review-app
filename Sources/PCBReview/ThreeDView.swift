import AppKit
import SceneKit
import SwiftUI
import simd
import KiCadKit

/// Drives the 3D board view and the view cube: a turntable camera around a
/// target point, the board with its textures, and the component models.
@MainActor
final class ThreeDController: ObservableObject {
    /// True for an orthographic camera, false for perspective.
    @Published var orthographic = false
    /// A note about the component models, e.g. how many were found.
    @Published private(set) var modelStatus: String?

    weak var mainView: SCNView?
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private var boardNode: SCNNode?
    private var componentsNode: SCNNode?
    private var builtKey: String?
    private var componentsKey: String?
    private var loadedURL: URL?

    // Board placement in the scene: board mm → scene metres around the board centre.
    private(set) var boardCenter = Point(0, 0)
    private(set) var thickness: Float = 0.0016
    private var boardSize: Float = 0.1

    // Turntable camera.
    private var target = SIMD3<Float>(0, 0, 0)
    private var yaw: Float = 0
    private var pitch: Float = 0.8
    private var distance: Float = 0.25

    /// The main camera's orientation, read by the view cube on its render thread.
    nonisolated let orientation = OrientationBox()
    /// A 2D mapping of the current 3D view, for the rulers and the viewfinder frame.
    /// Exact when looking straight down with the orthographic camera.
    let rulerViewport = Viewport()

    init() {
        let camera = SCNCamera()
        camera.zNear = 0.0005
        camera.zFar = 20
        camera.fieldOfView = 35
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        for (type, intensity, angles) in [(SCNLight.LightType.ambient, 420.0, SIMD3<Float>(0, 0, 0)),
                                           (.directional, 950, SIMD3(-1.0, 0.5, 0)),
                                           (.directional, 380, SIMD3(2.3, -0.6, 0))] {
            let n = SCNNode()
            n.light = SCNLight()
            n.light?.type = type
            n.light?.intensity = CGFloat(intensity)
            n.simdEulerAngles = angles
            scene.rootNode.addChildNode(n)
        }
    }

    // MARK: Building

    /// Builds (or rebuilds) the board for what the model shows. Does nothing if nothing changed.
    func load(_ model: BoardModel) {
        guard let input = model.input, let scene2D = model.scene, let bounds = input.board.outlineBounds else { return }
        let look = model.look
        let layers = model.visibleLayers
        let origin: Point? = model.showOrigin ? model.userOrigin : nil
        let key = "\(model.url?.path ?? "")|\(look)|\(layers.sorted())|\(model.showZoneFills)|\(model.showVias)|\(model.showComponents)|\(String(describing: origin))|\(model.renderColors.count)"
        let newBoard = loadedURL != model.url
        if key != builtKey, var mesh = BoardMesh.make(board: input.board, textureBounds: bounds) {
            mesh.materials[BoardMesh.edgeMaterial].baseColor = look.material
            let opts = BoardTextures.Options(look: look, layers: layers, zoneFills: model.showZoneFills, vias: model.showVias,
                                             components: model.showComponents, origin: origin)
            let images = ["F", "B"].compactMap { BoardTextures.image(scene: scene2D, bounds: bounds, side: $0, options: opts) }
            let node = Exporter.sceneNode(mesh, images: images, lighting: .blinn)
            for child in node.childNodes {
                child.geometry?.firstMaterial?.specular.contents = NSColor(white: 0.25, alpha: 1)
                child.geometry?.firstMaterial?.shininess = 0.3
            }
            boardNode?.removeFromParentNode()
            scene.rootNode.addChildNode(node)
            boardNode = node
            builtKey = key
        }
        boardCenter = Point(bounds.minX + bounds.width / 2, bounds.minY + bounds.height / 2)
        thickness = Float((input.board.thickness ?? 1.6) / 1000)
        boardSize = Float(max(bounds.width, bounds.height) / 1000)
        if newBoard {
            loadedURL = model.url
            home(animated: false)
        }
        loadComponents(model)
        componentsNode?.isHidden = !model.showComponents
    }

    private func loadComponents(_ model: BoardModel) {
        guard let input = model.input, let url = model.url else { return }
        let key = url.path
        guard key != componentsKey else { return }
        componentsKey = key
        componentsNode?.removeFromParentNode()
        componentsNode = nil
        modelStatus = "Loading component models…"
        let board = input.board, c = boardCenter, t = thickness
        let folder = url.deletingLastPathComponent()
        Task.detached(priority: .userInitiated) {
            let result = ComponentModels.build(board: board, boardFolder: folder, center: c, thickness: t)
            await MainActor.run {
                guard self.componentsKey == key else { return }
                self.scene.rootNode.addChildNode(result.node)
                self.componentsNode = result.node
                result.node.isHidden = !model.showComponents
                self.modelStatus = result.summary
            }
        }
    }

    // MARK: Camera

    private var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
    }

    private func applyCamera(animated: Bool = false) {
        let q = rotation
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.45 : 0
        cameraNode.simdOrientation = q
        cameraNode.simdPosition = target + q.act(SIMD3(0, 0, distance))
        cameraNode.camera?.orthographicScale = Double(distance * 0.32)
        cameraNode.camera?.usesOrthographicProjection = orthographic
        SCNTransaction.commit()
        orientation.set(q)
        let exact = orthographic && pitch > 1.55
        if exact != rulersExact { rulersExact = exact }
        updateRulers()
    }

    /// The starting view: from the front and above, looking at the board centre.
    func home(animated: Bool = true) {
        target = .zero
        yaw = 0
        pitch = 0.85
        distance = boardSize * 2.1
        applyCamera(animated: animated)
    }

    /// Looks at the board from `direction` (from the board centre towards the camera).
    func look(from direction: SIMD3<Float>) {
        let d = simd_normalize(direction)
        pitch = asin(max(-1, min(1, d.y)))
        let newYaw = abs(d.y) > 0.999 ? 0 : atan2(d.x, d.z)
        // Turn the short way round.
        var delta = newYaw - yaw
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        yaw += delta
        applyCamera(animated: true)
    }

    /// Turns the view by a drag of `dx`, `dy` points (positive dy is downwards).
    func orbit(dx: CGFloat, dy: CGFloat) {
        let speed = Float(AppSettings.number(AppSettings.orbitSpeed, default: 1)) * 0.008
        yaw -= Float(dx) * speed
        pitch = max(-.pi / 2, min(.pi / 2, pitch + Float(dy) * speed))
        applyCamera()
    }

    /// Moves the view so the board follows a drag of `dx`, `dy` points.
    func pan(dx: CGFloat, dy: CGFloat) {
        let h = Float(max(mainView?.bounds.height ?? 600, 1))
        let k = (orthographic ? distance * 0.64 : distance * 0.63) / h
        let q = rotation
        target -= q.act(SIMD3(1, 0, 0)) * Float(dx) * k
        target += q.act(SIMD3(0, 1, 0)) * Float(dy) * k
        applyCamera()
    }

    /// Zooms in for factors below 1, out above 1.
    func zoom(by factor: CGFloat) {
        distance = max(boardSize * 0.02, min(boardSize * 20, distance * Float(factor)))
        applyCamera()
    }

    /// Centres the view on a board point (mm).
    func center(onBoard p: Point) {
        target = SIMD3(Float((p.x - boardCenter.x) / 1000), thickness, Float((p.y - boardCenter.y) / 1000))
        applyCamera()
    }

    func setOrthographic(_ on: Bool) {
        orthographic = on
        applyCamera()
    }

    // MARK: Rulers

    /// Works out a 2D board-to-screen mapping from the 3D view at the board centre.
    func updateRulers() {
        guard let v = mainView, v.bounds.width > 0 else { return }
        let h = v.bounds.height
        func screen(_ bx: Double, _ by: Double) -> CGPoint {
            let s = v.projectPoint(SCNVector3(CGFloat((bx - boardCenter.x) / 1000), CGFloat(thickness), CGFloat((by - boardCenter.y) / 1000)))
            return CGPoint(x: s.x, y: h - s.y)
        }
        let c = boardCenter
        let p0 = screen(c.x, c.y), px = screen(c.x + 1, c.y), py = screen(c.x, c.y + 1)
        let sx = px.x - p0.x, sy = py.y - p0.y
        let scale = (abs(sx) + abs(sy)) / 2
        guard scale.isFinite, scale > 0.01 else { return }
        var t = ViewTransform(scale: scale, offset: .zero, flipX: sx < 0, flipY: sy < 0)
        t.offset = CGSize(width: p0.x - CGFloat(c.x) * t.sx, height: p0.y - CGFloat(c.y) * t.sy)
        rulerViewport.size = v.bounds.size
        rulerViewport.transform = t
    }

    /// True when the rulers match the 3D view exactly: looking straight down, orthographic.
    @Published private(set) var rulersExact = false
}

/// A lock-protected orientation shared between the two SceneKit render threads.
final class OrientationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
    func set(_ q: simd_quatf) { lock.lock(); value = q; lock.unlock() }
    func get() -> simd_quatf { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Textures

/// Board images for the 3D faces: solder mask, copper under the mask, exposed pads, silkscreen and holes.
enum BoardTextures {
    struct Options {
        var look: BoardLook
        var layers: Set<String>
        var zoneFills: Bool
        var vias: Bool
        var components: Bool
        var origin: Point?
    }

    @MainActor
    static func image(scene: BoardScene, bounds: Rect, side: String, options: Options) -> NSImage? {
        let pxPerMM = min(24, 4096 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * pxPerMM, height: bounds.height * pxPerMM)
        let view = Canvas { ctx, size in
            draw(scene: scene, bounds: bounds, side: side, options: options, in: ctx, size: size)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }

    static func color(_ c: RGBA, lighten: Double = 0) -> Color {
        Color(.sRGB, red: c.r + (1 - c.r) * lighten, green: c.g + (1 - c.g) * lighten, blue: c.b + (1 - c.b) * lighten, opacity: 1)
    }

    static func draw(scene: BoardScene, bounds: Rect, side: String, options o: Options, in ctx: GraphicsContext, size: CGSize) {
        let look = o.look
        let t = ViewTransform.fitting(bounds, in: size, margin: 1)
        var c = ctx
        c.concatenate(t.affine)
        c.fill(Path(CGRect(x: bounds.minX - 1, y: bounds.minY - 1, width: bounds.width + 2, height: bounds.height + 2)),
               with: .color(color(look.hasMask ? look.mask : look.material)))
        let showCopper = o.layers.contains("\(side).Cu")
        let copper = showCopper ? scene.paths["\(side).Cu"] : nil
        let bright = look.mask.r + look.mask.g + look.mask.b > 2
        let copperColor = look.hasMask ? color(look.mask, lighten: bright ? -0.1 : 0.16) : color(look.finish)
        if let cu = copper {
            if o.zoneFills { c.fill(cu.zoneFills, with: .color(copperColor)) }
            for g in cu.tracks {
                c.stroke(g.path, with: .color(copperColor), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
            }
            // Vias stay tented under the mask; pads are mask openings with the copper finish.
            if o.vias { c.fill(scene.viaPaths, with: .color(copperColor)) }
            if o.components { c.fill(cu.pads, with: .color(color(look.finish))) }
        }
        let silkColor = color(look.silk)
        if o.layers.contains("\(side).SilkS"), let silk = scene.paths["\(side).SilkS"] {
            c.fill(silk.filledGraphics, with: .color(silkColor))
            for g in silk.graphics {
                c.stroke(g.path, with: .color(silkColor), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
            }
            if o.components {
                c.fill(silk.componentFilled, with: .color(silkColor))
                for g in silk.componentGraphics {
                    c.stroke(g.path, with: .color(silkColor), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
                }
            }
        }
        let hole = Color(white: 0.04)
        c.fill(scene.holes, with: .color(hole))
        c.fill(scene.padHoles, with: .color(hole))
        if side == "F", let p = o.origin {
            var cross = Path()
            cross.move(to: CGPoint(x: p.x - 3, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 3, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - 3)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 3))
            let cyan = Color(red: 0.35, green: 0.85, blue: 0.95)
            c.stroke(cross, with: .color(cyan), lineWidth: 0.25)
            c.stroke(Path(ellipseIn: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8)), with: .color(cyan), lineWidth: 0.25)
        }
    }
}

// MARK: - Component models

/// Places each footprint's 3D model on the board: KiCad's VRML model when it
/// can be found, else a box the size of the footprint body.
enum ComponentModels {
    struct Result: @unchecked Sendable {
        let node: SCNNode
        let summary: String
    }

    static func build(board: Board, boardFolder: URL, center c: Point, thickness t: Float) -> Result {
        let root = SCNNode()
        root.name = "Components"
        var cache: [URL: [ModelPart]] = [:]
        var found = 0, boxes = 0
        for fp in board.footprints where !fp.pads.isEmpty {
            let lib = fp.libraryID.lowercased()
            if lib.contains("mountinghole") || lib.contains("fiducial") { continue }
            var placed = false
            for m in fp.models where !m.hidden {
                guard let url = ModelLibrary.resolve(m.path, boardFolder: boardFolder) else { continue }
                if cache[url] == nil { cache[url] = (try? VRMLReader.read(contentsOf: url)) ?? [] }
                guard let parts = cache[url], !parts.isEmpty else { continue }
                root.addChildNode(node(parts, footprint: fp, model: m, center: c, thickness: t))
                placed = true
            }
            if placed { found += 1 } else if let box = box(for: fp, center: c, thickness: t) {
                root.addChildNode(box)
                boxes += 1
            }
        }
        let summary = boxes == 0 ? "\(found) component models" :
            "\(found) component models found, \(boxes) shown as boxes (KiCad's .wrl model files were not found for them)"
        return Result(node: root, summary: summary)
    }

    /// The model's triangles in scene space, one geometry per colour.
    static func node(_ parts: [ModelPart], footprint fp: Footprint, model m: FootprintModel, center c: Point, thickness t: Float) -> SCNNode {
        func rad(_ d: Double) -> Float { Float(d * .pi / 180) }
        let rx = simd_quatf(angle: rad(m.rotation.x), axis: SIMD3(1, 0, 0))
        let ry = simd_quatf(angle: rad(m.rotation.y), axis: SIMD3(0, 1, 0))
        let rz = simd_quatf(angle: rad(m.rotation.z), axis: SIMD3(0, 0, 1))
        let modelRotation = rz * ry * rx
        let fpRotation = simd_quatf(angle: rad(fp.rotation), axis: SIMD3(0, 0, 1))
        let scale = SIMD3<Float>(Float(m.scale.x), Float(m.scale.y), Float(m.scale.z))
        let offset = SIMD3<Float>(Float(m.offset.x), Float(m.offset.y), Float(m.offset.z))
        let bottom = fp.isBottom
        func place(_ p: SIMD3<Float>) -> SIMD3<Float> {
            var v = modelRotation.act(p * scale) + offset
            if bottom { v = SIMD3(v.x, -v.y, -v.z) }
            v = fpRotation.act(v)
            let bx = Float(fp.position.x) + v.x, by = Float(fp.position.y) - v.y
            return SIMD3((bx - Float(c.x)) / 1000, (bottom ? 0 : t) + v.z / 1000, (by - Float(c.y)) / 1000)
        }
        let group = SCNNode()
        group.name = fp.reference
        for part in parts {
            var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
            vertices.reserveCapacity(part.indices.count)
            normals.reserveCapacity(part.indices.count)
            let pos = part.positions
            for k in stride(from: 0, to: part.indices.count - 2, by: 3) {
                let tri = (0..<3).map { j -> SIMD3<Float> in
                    let i = Int(part.indices[k + j]) * 3
                    return place(SIMD3(pos[i], pos[i + 1], pos[i + 2]))
                }
                var n = simd_cross(tri[1] - tri[0], tri[2] - tri[0])
                let len = simd_length(n)
                n = len > 0 ? n / len : SIMD3(0, 1, 0)
                // The bottom-side flip is a half turn about x, so winding and normals stay right.
                for v in tri {
                    vertices.append(SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)))
                    normals.append(SCNVector3(CGFloat(n.x), CGFloat(n.y), CGFloat(n.z)))
                }
            }
            guard !vertices.isEmpty else { continue }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                       elements: [SCNGeometryElement(indices: Array(0..<Int32(vertices.count)), primitiveType: .triangles)])
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(srgbRed: part.color.r, green: part.color.g, blue: part.color.b, alpha: part.color.a)
            mat.specular.contents = NSColor(white: 0.3, alpha: 1)
            mat.lightingModel = .blinn
            mat.isDoubleSided = true
            geometry.materials = [mat]
            group.addChildNode(SCNNode(geometry: geometry))
        }
        return group
    }

    /// A plain box for a footprint without a model, with a height guessed from its library name.
    static func box(for fp: Footprint, center c: Point, thickness t: Float) -> SCNNode? {
        guard let body = ComponentBody(fp) else { return nil }
        let lib = fp.libraryID.lowercased()
        let height: Double
        switch true {
        case lib.contains("0402"): height = 0.35
        case lib.contains("0603"): height = 0.45
        case lib.contains("0805"): height = 0.6
        case lib.contains("1206"), lib.contains("1210"): height = 0.65
        case lib.contains("testpoint"): height = 0.3
        case lib.contains("qfn"), lib.contains("dfn"): height = 0.9
        case lib.contains("sot"): height = 1.1
        case lib.contains("qfp"): height = 1.4
        case lib.contains("soic"), lib.contains("ssop"), lib.contains("tssop"): height = 1.5
        case lib.contains("connector"), lib.contains("rj45"): height = 6
        case lib.contains("transformer"), lib.contains("inductor"): height = 4
        default: height = 1.5
        }
        let box = SCNBox(width: CGFloat(body.width / 1000), height: CGFloat(height / 1000), length: CGFloat(body.height / 1000), chamferRadius: 0.00005)
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = lib.contains("capacitor") ? NSColor(srgbRed: 0.72, green: 0.58, blue: 0.38, alpha: 1)
            : lib.contains("led") ? NSColor(srgbRed: 0.92, green: 0.92, blue: 0.85, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        box.materials = [m]
        let n = SCNNode(geometry: box)
        n.name = fp.reference
        let y = fp.isBottom ? -Float(height / 2000) : t + Float(height / 2000)
        n.simdPosition = SIMD3(Float((body.center.x - c.x) / 1000), y, Float((body.center.y - c.y) / 1000))
        n.simdEulerAngles = SIMD3(0, Float(fp.rotation * .pi / 180), 0)
        return n
    }
}

// MARK: - Views

/// An SCNView that turns mouse, trackpad and scroll wheel input into camera moves, as set in Settings.
final class BoardSCNView: SCNView {
    weak var controller: ThreeDController?

    override var acceptsFirstResponder: Bool { true }

    private func perform(_ g: Gesture3D, dx: CGFloat, dy: CGFloat) {
        guard let c = controller else { return }
        switch g {
        case .orbit: c.orbit(dx: dx, dy: dy)
        case .pan: c.pan(dx: dx, dy: dy)
        case .zoom: zoom(dy * 0.01)
        case .none: break
        }
    }

    private func zoom(_ amount: CGFloat) {
        let speed = AppSettings.number(AppSettings.zoomSpeed, default: 1)
        let sign: CGFloat = UserDefaults.standard.bool(forKey: AppSettings.invertZoom) ? -1 : 1
        controller?.zoom(by: exp(amount * CGFloat(speed) * sign))
    }

    override func mouseDragged(with e: NSEvent) {
        let g: Gesture3D = e.modifierFlags.contains(.option) ? .pan
            : e.modifierFlags.contains(.shift) ? .zoom
            : AppSettings.gesture(AppSettings.leftDrag, default: .orbit)
        perform(g, dx: e.deltaX, dy: e.deltaY)
    }

    override func rightMouseDragged(with e: NSEvent) {
        perform(AppSettings.gesture(AppSettings.rightDrag, default: .pan), dx: e.deltaX, dy: e.deltaY)
    }

    override func otherMouseDragged(with e: NSEvent) {
        perform(AppSettings.gesture(AppSettings.middleDrag, default: .pan), dx: e.deltaX, dy: e.deltaY)
    }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas {
            var g = AppSettings.gesture(AppSettings.trackpadScroll, default: .pan)
            if e.modifierFlags.contains(.option) { g = g == .orbit ? .pan : .orbit }
            if g == .zoom { zoom(-e.scrollingDeltaY * 0.01) } else { perform(g, dx: e.scrollingDeltaX, dy: e.scrollingDeltaY) }
        } else {
            let g = AppSettings.gesture(AppSettings.scrollWheel, default: .zoom)
            if g == .zoom { zoom(-e.scrollingDeltaY * 0.08) } else { perform(g, dx: e.scrollingDeltaX * 8, dy: e.scrollingDeltaY * 8) }
        }
    }

    override func magnify(with e: NSEvent) {
        controller?.zoom(by: max(0.2, 1 - e.magnification))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.updateRulers()
    }
}

/// The 3D board.
struct Board3DView: NSViewRepresentable {
    @ObservedObject var controller: ThreeDController

    func makeNSView(context: Context) -> BoardSCNView {
        let v = BoardSCNView(frame: .zero)
        v.scene = controller.scene
        v.pointOfView = controller.cameraNode
        v.allowsCameraControl = false
        v.backgroundColor = NSColor(red: 0.09, green: 0.1, blue: 0.11, alpha: 1)
        v.antialiasingMode = .multisampling4X
        v.isPlaying = true
        v.controller = controller
        controller.mainView = v
        return v
    }

    func updateNSView(_ v: BoardSCNView, context: Context) {}
}

/// The view cube: turns with the 3D view. Click a face to look from that side, drag to turn the board.
struct ViewCubeView: View {
    @EnvironmentObject var controller: ThreeDController

    var body: some View {
        ZStack(alignment: .top) {
            ViewCubeScene(controller: controller)
            HStack {
                Button { controller.home() } label: { Image(systemName: "house.fill") }
                    .help("Home view")
                Spacer()
                Button { controller.setOrthographic(!controller.orthographic) } label: {
                    Image(systemName: controller.orthographic ? "eye.square.fill" : "eye")
                }
                .help(controller.orthographic ? "Orthographic (click for perspective)" : "Perspective (click for orthographic)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 20))
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
    }
}

struct ViewCubeScene: NSViewRepresentable {
    let controller: ThreeDController

    /// Box faces in SceneKit's order and the direction each one looks from.
    static let faces: [(label: String, from: SIMD3<Float>)] = [
        ("FRONT", SIMD3(0, 0, 1)), ("RIGHT", SIMD3(1, 0, 0)), ("BACK", SIMD3(0, 0, -1)),
        ("LEFT", SIMD3(-1, 0, 0)), ("TOP", SIMD3(0, 1, 0)), ("BOTTOM", SIMD3(0, -1, 0)),
    ]

    func makeNSView(context: Context) -> CubeSCNView {
        let v = CubeSCNView(frame: .zero)
        v.controller = controller
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        let scene = SCNScene()
        let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.08)
        box.materials = Self.faces.map { face in
            let m = SCNMaterial()
            m.diffuse.contents = Self.faceImage(face.label)
            m.lightingModel = .constant
            return m
        }
        scene.rootNode.addChildNode(SCNNode(geometry: box))
        // Axes from the lower left front corner: X right, Y to the back, Z up (board convention).
        let corner = SIMD3<Float>(-0.62, -0.62, 0.62)
        for (dir, color, label) in [(SIMD3<Float>(1, 0, 0), NSColor.systemRed, "X"),
                                    (SIMD3<Float>(0, 0, -1), NSColor.systemGreen, "Y"),
                                    (SIMD3<Float>(0, 1, 0), NSColor.systemBlue, "Z")] {
            let length: Float = 1.25
            let cyl = SCNCylinder(radius: 0.025, height: CGFloat(length))
            cyl.firstMaterial?.diffuse.contents = color
            cyl.firstMaterial?.lightingModel = .constant
            let n = SCNNode(geometry: cyl)
            n.simdPosition = corner + dir * (length / 2)
            n.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: dir)
            scene.rootNode.addChildNode(n)
            let text = SCNText(string: label, extrusionDepth: 0)
            text.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            text.flatness = 0.1
            text.firstMaterial?.diffuse.contents = color
            text.firstMaterial?.lightingModel = .constant
            let tn = SCNNode(geometry: text)
            let (minB, maxB) = tn.boundingBox
            tn.pivot = SCNMatrix4MakeTranslation((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, 0)
            tn.simdScale = SIMD3(repeating: 0.03)
            tn.simdPosition = corner + dir * (length + 0.15)
            tn.constraints = [SCNBillboardConstraint()]
            scene.rootNode.addChildNode(tn)
        }
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.camera?.usesOrthographicProjection = true
        camNode.camera?.orthographicScale = 1.25
        scene.rootNode.addChildNode(camNode)
        v.scene = scene
        v.pointOfView = camNode
        v.delegate = context.coordinator
        v.isPlaying = true
        context.coordinator.cameraNode = camNode
        return v
    }

    func updateNSView(_ v: CubeSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(box: controller.orientation) }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let box: OrientationBox
        var cameraNode: SCNNode?
        init(box: OrientationBox) { self.box = box }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let cam = cameraNode else { return }
            let q = box.get()
            cam.simdOrientation = q
            cam.simdPosition = q.act(SIMD3(0, 0, 4))
        }
    }

    static func faceImage(_ label: String) -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 2, y: 2, width: 124, height: 124))
        border.lineWidth = 4
        border.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.count > 5 ? 22 : 26, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1),
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        let ts = s.size()
        s.draw(at: NSPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2))
        image.unlockFocus()
        return image
    }
}

/// The cube's view: a click on a face looks from that side, a drag turns the board.
final class CubeSCNView: SCNView {
    weak var controller: ThreeDController?
    private var dragged = false

    override func mouseDown(with e: NSEvent) { dragged = false }

    override func mouseDragged(with e: NSEvent) {
        dragged = true
        controller?.orbit(dx: e.deltaX * 1.5, dy: e.deltaY * 1.5)
    }

    override func mouseUp(with e: NSEvent) {
        guard !dragged else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard let hit = hitTest(p, options: nil).first(where: { $0.node.geometry is SCNBox }) else { return }
        let i = hit.geometryIndex
        guard i >= 0, i < ViewCubeScene.faces.count else { return }
        controller?.look(from: ViewCubeScene.faces[i].from)
    }
}
