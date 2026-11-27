import AppKit
import PDFKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers
import KiCadKit

/// Export formats offered in File › Export.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF", png = "PNG", svg = "SVG", usdz = "USDZ", glb = "GLB", hpgl = "HP-GL"
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .svg: return "svg"
        case .usdz: return "usdz"
        case .glb: return "glb"
        case .hpgl: return "plt"
        }
    }

    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .data }

    var menuTitle: String {
        switch self {
        case .pdf: return "PDF (true scale)…"
        case .png: return "PNG Image…"
        case .svg: return "SVG Drawing…"
        case .usdz: return "USDZ 3D Model…"
        case .glb: return "GLB 3D Model…"
        case .hpgl: return "HP-GL Plot…"
        }
    }
}

/// Printing and exports. 2D outputs show what the canvas shows: the current
/// tab's layers with their colours, fills, vias, flips and dimensions, fitted to the whole board.
@MainActor
enum Exporter {
    static let pngPixelsPerMM: CGFloat = 20
    static let textureBackground = Color(red: 0.06, green: 0.22, blue: 0.12)

    // MARK: Entry points

    static func export(_ format: ExportFormat, model: BoardModel, viewport: Viewport) {
        guard let input = model.input, let scene = model.scene else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let base = model.url?.deletingPathExtension().lastPathComponent ?? "board"
        let suffix = model.tab == .all ? "" : "-" + model.title(of: model.tab).components(separatedBy: " ").first!
        panel.nameFieldStringValue = "\(base)\(suffix).\(format.fileExtension)"
        panel.message = "Export \(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .pdf:
                try pdfData(model: model, viewport: viewport, scene: scene).write(to: url)
            case .png:
                try pngData(model: model, viewport: viewport, scene: scene).write(to: url)
            case .svg:
                let svg = SVGExporter.svg(board: input.board, options: vectorOptions(model: model, viewport: viewport, scene: scene))
                try svg.write(to: url, atomically: true, encoding: .utf8)
            case .hpgl:
                let plt = HPGLExporter.hpgl(board: input.board, options: vectorOptions(model: model, viewport: viewport, scene: scene))
                try plt.write(to: url, atomically: true, encoding: .ascii)
            case .glb:
                let (mesh, images) = try model3D(model: model, board: input.board, scene: scene)
                try GLBWriter.write(mesh, images: images.map(\.png)).write(to: url)
            case .usdz:
                let (mesh, images) = try model3D(model: model, board: input.board, scene: scene)
                try writeUSDZ(mesh, images: images.map(\.image), to: url)
            }
        } catch {
            model.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    static func pageSetup(model: BoardModel) {
        NSPageLayout().runModal(with: model.printInfo)
    }

    /// Prints the board scaled to fit the page set in Page Setup.
    static func print(model: BoardModel, viewport: Viewport) {
        guard let scene = model.scene else { return }
        do {
            let data = try pdfData(model: model, viewport: viewport, scene: scene, forPrint: true)
            guard let doc = PDFDocument(data: data),
                  let op = doc.printOperation(for: model.printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
                model.errorMessage = "Could not prepare the print job."
                return
            }
            op.jobTitle = model.windowTitle
            op.showsPrintPanel = true
            op.showsProgressPanel = true
            op.run()
        } catch {
            model.errorMessage = "Printing failed: \(error.localizedDescription)"
        }
    }

    // MARK: 2D

    /// The board area to export, in mm: the board plus room for dimensions.
    static func exportRect(model: BoardModel, scene: BoardScene) -> Rect {
        let m: Double = model.dimensions.isEmpty ? 3 : 12
        let b = scene.bounds
        return Rect(minX: b.minX - m, minY: b.minY - m, maxX: b.maxX + m, maxY: b.maxY + m)
    }

    static func picture(model: BoardModel, viewport: Viewport, scene: BoardScene, forPrint: Bool = false) -> BoardPictureView {
        var options = model.renderOptions
        options.highlight = nil
        options.fillBackground = !forPrint
        return BoardPictureView(
            scene: scene, fitRect: exportRect(model: model, scene: scene), options: options,
            flipX: viewport.flipX, flipY: viewport.flipY, margin: 1,
            overlay: (origin: nil, dimensions: model.dimensions,
                      color: model.color(of: BoardModel.drawingsLayer), units: model.units))
    }

    /// A one-page PDF at true scale (1 mm on the board is 1 mm on paper).
    static func pdfData(model: BoardModel, viewport: Viewport, scene: BoardScene, forPrint: Bool = false) throws -> Data {
        let r = exportRect(model: model, scene: scene)
        let pointsPerMM: CGFloat = 72 / 25.4
        let size = CGSize(width: CGFloat(r.width) * pointsPerMM, height: CGFloat(r.height) * pointsPerMM)
        let content = picture(model: model, viewport: viewport, scene: scene, forPrint: forPrint)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        let data = NSMutableData()
        var ok = false
        renderer.render { renderSize, draw in
            var box = CGRect(origin: .zero, size: renderSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        guard ok else { throw ExportError.renderFailed }
        return data as Data
    }

    static func pngData(model: BoardModel, viewport: Viewport, scene: BoardScene) throws -> Data {
        let r = exportRect(model: model, scene: scene)
        let size = CGSize(width: CGFloat(r.width) * pngPixelsPerMM, height: CGFloat(r.height) * pngPixelsPerMM)
        let content = picture(model: model, viewport: viewport, scene: scene).frame(width: size.width, height: size.height)
        return try png(of: content)
    }

    static func vectorOptions(model: BoardModel, viewport: Viewport, scene: BoardScene) -> ExportOptions {
        let drawn = model.drawnLayers
        var o = ExportOptions(layers: scene.drawOrder.filter { drawn.contains($0) },
                              colors: model.renderColors.mapValues(\.rgba))
        o.showZoneFills = model.showZoneFills
        o.showVias = model.showVias
        o.flipX = viewport.flipX
        o.flipY = viewport.flipY
        return o
    }

    // MARK: 3D

    struct Texture { let png: Data; let image: NSImage }

    /// The board slab with images of the top and bottom sides as textures.
    static func model3D(model: BoardModel, board: Board, scene: BoardScene) throws -> (Mesh3D, [Texture]) {
        guard let bounds = board.outlineBounds, let mesh = BoardMesh.make(board: board, textureBounds: bounds) else {
            throw ExportError.noOutline
        }
        func side(_ layers: Set<String>) throws -> Texture {
            var options = RenderOptions(layers: layers, colors: model.renderColors)
            options.showZoneFills = model.showZoneFills
            let size = CGSize(width: CGFloat(bounds.width) * pngPixelsPerMM, height: CGFloat(bounds.height) * pngPixelsPerMM)
            let content = BoardPictureView(scene: scene, fitRect: bounds, options: options, margin: 1)
                .frame(width: size.width, height: size.height)
                .background(textureBackground)
            let data = try png(of: content)
            guard let image = NSImage(data: data) else { throw ExportError.renderFailed }
            return Texture(png: data, image: image)
        }
        let top = try side(["F.Cu", "F.SilkS", "Edge.Cuts"])
        let bottom = try side(["B.Cu", "B.SilkS", "Edge.Cuts"])
        return (mesh, [top, bottom])
    }

    static func writeUSDZ(_ mesh: Mesh3D, images: [NSImage], to url: URL) throws {
        let scn = SCNScene()
        let root = SCNNode()
        root.name = mesh.name
        for p in mesh.primitives where !p.indices.isEmpty {
            let n = p.vertexCount
            let vertices = (0..<n).map { SCNVector3(CGFloat(p.positions[$0 * 3]), CGFloat(p.positions[$0 * 3 + 1]), CGFloat(p.positions[$0 * 3 + 2])) }
            let normals = (0..<n).map { SCNVector3(CGFloat(p.normals[$0 * 3]), CGFloat(p.normals[$0 * 3 + 1]), CGFloat(p.normals[$0 * 3 + 2])) }
            let uvs = (0..<n).map { CGPoint(x: CGFloat(p.uvs[$0 * 2]), y: CGFloat(p.uvs[$0 * 2 + 1])) }
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                          SCNGeometrySource(textureCoordinates: uvs)],
                elements: [SCNGeometryElement(indices: p.indices, primitiveType: .triangles)])
            let m = mesh.materials[p.material]
            let material = SCNMaterial()
            material.name = m.name
            material.lightingModel = .physicallyBased
            if let i = m.image, i < images.count {
                material.diffuse.contents = images[i]
            } else {
                material.diffuse.contents = NSColor(srgbRed: m.baseColor.r, green: m.baseColor.g, blue: m.baseColor.b, alpha: m.baseColor.a)
            }
            material.roughness.contents = m.roughness
            material.metalness.contents = m.metallic
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.name = m.name
            root.addChildNode(node)
        }
        scn.rootNode.addChildNode(root)
        guard scn.write(to: url, options: nil, delegate: nil, progressHandler: nil) else { throw ExportError.writeFailed }
    }

    // MARK: Helpers

    static func png<V: View>(of view: V) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { throw ExportError.renderFailed }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ExportError.renderFailed }
        return data
    }

    enum ExportError: LocalizedError {
        case renderFailed, noOutline, writeFailed
        var errorDescription: String? {
            switch self {
            case .renderFailed: return "The board could not be rendered."
            case .noOutline: return "The board outline (Edge.Cuts) does not form a closed shape."
            case .writeFailed: return "The file could not be written."
            }
        }
    }
}
