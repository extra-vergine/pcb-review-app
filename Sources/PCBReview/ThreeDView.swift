import AppKit
import SceneKit
import SwiftUI
import simd
import KiCadKit

/// Drives the 3D board view and the view cube: camera moves, home, projection.
@MainActor
final class ThreeDController: ObservableObject {
    /// True for an orthographic camera, false for perspective.
    @Published var orthographic = false
    @Published private(set) var isBuilding = false

    weak var mainView: SCNView?
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private var boardNode: SCNNode?
    private var builtKey: String?
    /// Largest board dimension in scene units (metres).
    private var boardSize: Float = 0.1

    /// The main camera's orientation, read by the view cube on its render thread.
    nonisolated let orientation = OrientationBox()

    init() {
        let camera = SCNCamera()
        camera.zNear = 0.0005
        camera.zFar = 20
        camera.fieldOfView = 35
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.simdEulerAngles = SIMD3(-1.0, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 350
        fill.simdEulerAngles = SIMD3(2.3, -0.6, 0)
        scene.rootNode.addChildNode(fill)
    }

    /// Builds (or rebuilds) the board with the current look. Does nothing if nothing changed.
    func load(_ model: BoardModel) {
        guard let input = model.input, let scene3 = model.scene, let bounds = input.board.outlineBounds else { return }
        let look = model.look
        let key = "\(model.url?.path ?? "")|\(look)|\(model.showComponents)"
        guard key != builtKey else { return }
        guard var mesh = BoardMesh.make(board: input.board, textureBounds: bounds) else { return }
        isBuilding = true
        mesh.materials[BoardMesh.edgeMaterial].baseColor = look.material
        let top = BoardTextures.image(scene: scene3, bounds: bounds, side: "F", look: look, components: model.showComponents)
        let bottom = BoardTextures.image(scene: scene3, bounds: bounds, side: "B", look: look, components: model.showComponents)
        let node = Exporter.sceneNode(mesh, images: [top, bottom].compactMap { $0 }, lighting: .blinn)
        for child in node.childNodes {
            child.geometry?.firstMaterial?.specular.contents = NSColor(white: 0.25, alpha: 1)
            child.geometry?.firstMaterial?.shininess = 0.3
        }
        boardNode?.removeFromParentNode()
        scene.rootNode.addChildNode(node)
        boardNode = node
        let first = builtKey?.hasPrefix("\(model.url?.path ?? "")|") != true
        builtKey = key
        boardSize = Float(max(bounds.width, bounds.height) / 1000)
        if first { home(animated: false) }
        isBuilding = false
    }

    private var distance: Float { boardSize * 2.2 }

    /// The starting view: from the front, above the board, looking at its centre.
    func home(animated: Bool = true) {
        move(to: simd_normalize(SIMD3<Float>(0, 1.1, 0.9)) * distance, up: SIMD3(0, 1, 0), animated: animated)
    }

    /// Looks at the board from `direction` (a unit vector from the board centre).
    func look(from direction: SIMD3<Float>, up: SIMD3<Float>) {
        let pov = mainView?.pointOfView ?? cameraNode
        let d = max(simd_length(pov.simdWorldPosition), boardSize * 0.3)
        move(to: simd_normalize(direction) * d, up: up, animated: true)
    }

    private func move(to position: SIMD3<Float>, up: SIMD3<Float>, animated: Bool) {
        let pov = mainView?.pointOfView ?? cameraNode
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.45 : 0
        pov.simdWorldPosition = position
        pov.simdLook(at: .zero, up: up, localFront: SIMD3(0, 0, -1))
        pov.camera?.orthographicScale = Double(simd_length(position) * 0.42)
        SCNTransaction.commit()
        mainView?.defaultCameraController.target = SCNVector3(0, 0, 0)
        orientation.set(pov.simdWorldOrientation)
    }

    func setOrthographic(_ on: Bool) {
        orthographic = on
        let pov = mainView?.pointOfView ?? cameraNode
        pov.camera?.orthographicScale = Double(simd_length(pov.simdWorldPosition) * 0.42)
        pov.camera?.usesOrthographicProjection = on
    }
}

/// A lock-protected orientation shared between the two SceneKit render threads.
final class OrientationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
    func set(_ q: simd_quatf) { lock.lock(); value = q; lock.unlock() }
    func get() -> simd_quatf { lock.lock(); defer { lock.unlock() }; return value }
}

/// Board images for the 3D faces: solder mask, copper under the mask, exposed pads, silkscreen and holes.
enum BoardTextures {
    @MainActor
    static func image(scene: BoardScene, bounds: Rect, side: String, look: BoardLook, components: Bool) -> NSImage? {
        let pxPerMM = min(24, 4096 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * pxPerMM, height: bounds.height * pxPerMM)
        let view = Canvas { ctx, size in
            draw(scene: scene, bounds: bounds, side: side, look: look, components: components, in: ctx, size: size)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }

    static func color(_ c: RGBA, lighten: Double = 0) -> Color {
        Color(.sRGB, red: c.r + (1 - c.r) * lighten, green: c.g + (1 - c.g) * lighten, blue: c.b + (1 - c.b) * lighten, opacity: 1)
    }

    static func draw(scene: BoardScene, bounds: Rect, side: String, look: BoardLook, components: Bool,
                     in ctx: GraphicsContext, size: CGSize) {
        let t = ViewTransform.fitting(bounds, in: size, margin: 1)
        var c = ctx
        c.concatenate(t.affine)
        c.fill(Path(CGRect(x: bounds.minX - 1, y: bounds.minY - 1, width: bounds.width + 2, height: bounds.height + 2)),
               with: .color(color(look.hasMask ? look.mask : look.material)))
        let copper = scene.paths["\(side).Cu"]
        let copperColor = look.hasMask ? color(look.mask, lighten: look.mask.r + look.mask.g + look.mask.b > 2 ? -0.1 : 0.16)
                                       : color(look.finish)
        if let cu = copper {
            c.fill(cu.zoneFills, with: .color(copperColor))
            for g in cu.tracks {
                c.stroke(g.path, with: .color(copperColor), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
            }
        }
        // Vias stay tented under the mask; pads are mask openings with the copper finish.
        c.fill(scene.viaPaths, with: .color(copperColor))
        if let cu = copper {
            c.fill(cu.pads, with: .color(color(look.finish)))
        }
        let silkColor = Color(.sRGB, red: look.silk.r, green: look.silk.g, blue: look.silk.b, opacity: 1)
        if let silk = scene.paths["\(side).SilkS"] {
            c.fill(silk.filledGraphics, with: .color(silkColor))
            for g in silk.graphics {
                c.stroke(g.path, with: .color(silkColor), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
            }
            if components {
                c.fill(silk.componentFilled, with: .color(silkColor))
                for g in silk.componentGraphics {
                    c.stroke(g.path, with: .color(silkColor), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
                }
            }
        }
        let hole = Color(white: 0.04)
        c.fill(scene.holes, with: .color(hole))
        c.fill(scene.padHoles, with: .color(hole))
    }
}

/// The 3D board: orbit by dragging, pan with two fingers or ⌥-drag, zoom by pinching or scrolling.
struct Board3DView: NSViewRepresentable {
    @ObservedObject var controller: ThreeDController

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = controller.scene
        v.pointOfView = controller.cameraNode
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.defaultCameraController.target = SCNVector3(0, 0, 0)
        v.backgroundColor = NSColor(red: 0.09, green: 0.1, blue: 0.11, alpha: 1)
        v.antialiasingMode = .multisampling4X
        v.delegate = context.coordinator
        v.isPlaying = true
        controller.mainView = v
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        v.pointOfView?.camera?.usesOrthographicProjection = controller.orthographic
    }

    func makeCoordinator() -> Coordinator { Coordinator(box: controller.orientation) }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let box: OrientationBox
        init(box: OrientationBox) { self.box = box }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            if let pov = renderer.pointOfView { box.set(pov.presentation.simdWorldOrientation) }
        }
    }
}

/// The view cube: turns with the 3D view; click a face to look from that side.
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
            .font(.system(size: 13))
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
    }
}

struct ViewCubeScene: NSViewRepresentable {
    let controller: ThreeDController

    /// Box faces in SceneKit's order, with where to look from and which way is up.
    static let faces: [(label: String, from: SIMD3<Float>, up: SIMD3<Float>)] = [
        ("FRONT", SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
        ("RIGHT", SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
        ("BACK", SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
        ("LEFT", SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ("TOP", SIMD3(0, 1, 0), SIMD3(0, 0, -1)),
        ("BOTTOM", SIMD3(0, -1, 0), SIMD3(0, 0, 1)),
    ]

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
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
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        v.addGestureRecognizer(click)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let controller: ThreeDController
        let box: OrientationBox
        var cameraNode: SCNNode?
        init(controller: ThreeDController) {
            self.controller = controller
            self.box = controller.orientation
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let cam = cameraNode else { return }
            let q = box.get()
            cam.simdOrientation = q
            cam.simdPosition = q.act(SIMD3(0, 0, 4))
        }

        @MainActor @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let v = g.view as? SCNView else { return }
            let p = g.location(in: v)
            guard let hit = v.hitTest(p, options: nil).first(where: { $0.node.geometry is SCNBox }) else { return }
            let i = hit.geometryIndex
            guard i >= 0, i < ViewCubeScene.faces.count else { return }
            let face = ViewCubeScene.faces[i]
            controller.look(from: face.from, up: face.up)
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
