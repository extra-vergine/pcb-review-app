import AppKit
import ModelIO
import PDFKit
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import UniformTypeIdentifiers
import KiCadKit

/// Export formats offered in File › Export.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF", png = "PNG", svg = "SVG", usd = "USD", glb = "GLB", hpgl = "HP-GL"
    var id: String { rawValue }

    var is3D: Bool { self == .usd || self == .glb }

    var defaultExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .svg: return "svg"
        case .usd: return "usdz"
        case .glb: return "glb"
        case .hpgl: return "plt"
        }
    }

    var menuTitle: String {
        switch self {
        case .pdf: return "PDF (true scale)…"
        case .png: return "PNG Image…"
        case .svg: return "SVG Drawing…"
        case .usd: return "USD 3D Model…"
        case .glb: return "GLB 3D Model…"
        case .hpgl: return "HP-GL Plot…"
        }
    }
}

/// The USD file flavours.
enum USDKind: String, CaseIterable, Identifiable {
    case usdz, usd, usda, usdc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .usdz: return "USDZ (one file, textures inside)"
        case .usd: return "USD"
        case .usda: return "USDA (text)"
        case .usdc: return "USDC (binary)"
        }
    }
}

/// The choices on the export panel, remembered between exports.
@MainActor
final class ExportSettings: ObservableObject {
    @Published var includeDimensions: Bool
    @Published var usdKind: USDKind
    @Published var pngPixelsPerMM: Double
    @Published var pngAlpha: Bool
    /// The path of the chosen Quartz filter, or "" for none.
    @Published var pdfFilter: String
    @Published var svgDecimals: Int
    @Published var svgTextAsCurves: Bool
    @Published var hpgl2: Bool

    private static let d = UserDefaults.standard

    init(includeDimensions: Bool) {
        let d = Self.d
        self.includeDimensions = includeDimensions
        usdKind = USDKind(rawValue: d.string(forKey: "export.usdKind") ?? "") ?? .usdz
        pngPixelsPerMM = d.object(forKey: "export.pngPPMM") == nil ? 20 : d.double(forKey: "export.pngPPMM")
        pngAlpha = d.bool(forKey: "export.pngAlpha")
        pdfFilter = d.string(forKey: "export.pdfFilter") ?? ""
        svgDecimals = d.object(forKey: "export.svgDecimals") == nil ? 4 : d.integer(forKey: "export.svgDecimals")
        svgTextAsCurves = d.bool(forKey: "export.svgCurves")
        hpgl2 = d.object(forKey: "export.hpgl2") == nil ? true : d.bool(forKey: "export.hpgl2")
    }

    func save() {
        let d = Self.d
        d.set(usdKind.rawValue, forKey: "export.usdKind")
        d.set(pngPixelsPerMM, forKey: "export.pngPPMM")
        d.set(pngAlpha, forKey: "export.pngAlpha")
        d.set(pdfFilter, forKey: "export.pdfFilter")
        d.set(svgDecimals, forKey: "export.svgDecimals")
        d.set(svgTextAsCurves, forKey: "export.svgCurves")
        d.set(hpgl2, forKey: "export.hpgl2")
    }

    func fileExtension(for format: ExportFormat) -> String {
        format == .usd ? usdKind.rawValue : format.defaultExtension
    }
}

/// The options shown under the save panel, for one format.
struct ExportOptionsView: View {
    let format: ExportFormat
    @ObservedObject var settings: ExportSettings
    /// Quartz filters: name and file path.
    let filters: [(name: String, path: String)]
    let onUSDKindChange: (USDKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include dimensions", isOn: $settings.includeDimensions)
                .disabled(format.is3D)
            if format.is3D {
                caption("Dimensions are drawn only in 2D exports.")
            } else {
                caption("The dimensions switched on in the layer panel, or the board's width and height if none are.")
            }
            switch format {
            case .usd:
                Picker("Format", selection: $settings.usdKind) {
                    ForEach(USDKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.usdKind) { onUSDKindChange($0) }
            case .png:
                Picker("Resolution", selection: $settings.pngPixelsPerMM) {
                    ForEach([10.0, 20, 40, 80], id: \.self) { v in
                        Text("\(Int(v)) px per mm (\(Int((v * 25.4).rounded())) dpi)").tag(v)
                    }
                }
                Toggle("Transparent background (alpha)", isOn: $settings.pngAlpha)
            case .pdf:
                Picker("Quartz filter", selection: $settings.pdfFilter) {
                    Text("None").tag("")
                    ForEach(filters, id: \.path) { Text($0.name).tag($0.path) }
                }
            case .svg:
                Picker("Resolution", selection: $settings.svgDecimals) {
                    Text("0.01 mm").tag(2)
                    Text("0.001 mm").tag(3)
                    Text("0.0001 mm").tag(4)
                    Text("0.00001 mm").tag(5)
                }
                Toggle("Text as curves", isOn: $settings.svgTextAsCurves)
            case .hpgl:
                Picker("Dialect", selection: $settings.hpgl2) {
                    Text("HP-GL/2").tag(true)
                    Text("HP-GL").tag(false)
                }
                .pickerStyle(.segmented)
            case .glb:
                EmptyView()
            }
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Printing and exports. 2D outputs show what the canvas shows: the current
/// tab's layers with their colours, fills, vias, flips and dimensions, fitted to the whole board.
@MainActor
enum Exporter {
    /// Resolution of the 3D textures.
    static let pngPixelsPerMM: CGFloat = 20
    static let textureBackground = Color(red: 0.06, green: 0.22, blue: 0.12)

    // MARK: Entry points

    static func export(_ format: ExportFormat, model: BoardModel, viewport: Viewport) {
        guard let input = model.input, let scene = model.scene else { return }
        let settings = ExportSettings(includeDimensions: model.anyDimensionShown)
        let panel = NSSavePanel()
        func contentType() -> UTType { UTType(filenameExtension: settings.fileExtension(for: format)) ?? .data }
        panel.allowedContentTypes = [contentType()]
        let base = model.url?.deletingPathExtension().lastPathComponent ?? "board"
        let suffix = model.tab == .all ? "" : "-" + model.title(of: model.tab).components(separatedBy: " ").first!
        panel.nameFieldStringValue = "\(base)\(suffix).\(settings.fileExtension(for: format))"
        panel.message = "Export \(format.rawValue)"
        panel.isExtensionHidden = false
        let filters = format == .pdf ? quartzFilters() : []
        let host = NSHostingView(rootView: ExportOptionsView(
            format: format, settings: settings, filters: filters,
            onUSDKindChange: { [weak panel] kind in
                guard let panel else { return }
                panel.allowedContentTypes = [UTType(filenameExtension: kind.rawValue) ?? .data]
                let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
                panel.nameFieldStringValue = name + "." + kind.rawValue
            }))
        host.setFrameSize(host.fittingSize)
        panel.accessoryView = host
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.save()

        let dims = settings.includeDimensions && !format.is3D ? exportDimensions(model: model) : []
        do {
            switch format {
            case .pdf:
                let filter: QuartzFilter? = settings.pdfFilter.isEmpty ? nil : QuartzFilter(url: URL(fileURLWithPath: settings.pdfFilter))
                try pdfData(model: model, viewport: viewport, scene: scene, dimensions: dims, filter: filter).write(to: url)
            case .png:
                try pngData(model: model, viewport: viewport, scene: scene, dimensions: dims,
                            pixelsPerMM: CGFloat(settings.pngPixelsPerMM), alpha: settings.pngAlpha).write(to: url)
            case .svg:
                var o = vectorOptions(model: model, viewport: viewport, scene: scene, dimensions: dims)
                o.decimals = settings.svgDecimals
                if settings.svgTextAsCurves { o.textToPath = { @Sendable text, height in textOutline(text, height) } }
                try SVGExporter.svg(board: input.board, options: o).write(to: url, atomically: true, encoding: .utf8)
            case .hpgl:
                var o = vectorOptions(model: model, viewport: viewport, scene: scene, dimensions: dims)
                o.hpgl2 = settings.hpgl2
                try HPGLExporter.hpgl(board: input.board, options: o).write(to: url, atomically: true, encoding: .ascii)
            case .glb:
                let (mesh, images) = try model3D(model: model, board: input.board, scene: scene)
                try GLBWriter.write(mesh, images: images.map(\.png)).write(to: url)
            case .usd:
                let (mesh, images) = try model3D(model: model, board: input.board, scene: scene)
                try writeUSD(mesh, images: images.map(\.image), to: url, kind: settings.usdKind)
            }
        } catch {
            model.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// The Quartz filters installed on this Mac (the ones ColorSync Utility lists).
    static func quartzFilters() -> [(name: String, path: String)] {
        let all = (QuartzFilterManager.filters(inDomains: nil) as? [QuartzFilter]) ?? []
        return all.compactMap { f in
            guard let url = f.url() else { return nil }
            return (name: f.localizedName() ?? url.deletingPathExtension().lastPathComponent, path: url.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The dimensions shown in the layer panel, or the overall width and height when none are.
    static func exportDimensions(model: BoardModel) -> [LinearDimension] {
        if !model.dimensions.isEmpty { return model.dimensions }
        guard let board = model.input?.board else { return [] }
        return [board.overallDimension(.horizontal), board.overallDimension(.vertical)].compactMap { $0 }
    }

    static func pageSetup(model: BoardModel) {
        NSPageLayout().runModal(with: model.printInfo)
    }

    /// Prints the board scaled to fit the page set in Page Setup.
    static func print(model: BoardModel, viewport: Viewport) {
        guard let scene = model.scene else { return }
        do {
            let data = try pdfData(model: model, viewport: viewport, scene: scene, dimensions: model.dimensions, forPrint: true)
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
    static func exportRect(scene: BoardScene, dimensions: [LinearDimension]) -> Rect {
        let m: Double = dimensions.isEmpty ? 3 : 12
        let b = scene.bounds
        return Rect(minX: b.minX - m, minY: b.minY - m, maxX: b.maxX + m, maxY: b.maxY + m)
    }

    static func picture(model: BoardModel, viewport: Viewport, scene: BoardScene, dimensions: [LinearDimension],
                        background: Bool = true) -> BoardPictureView {
        var options = model.renderOptions
        options.highlight = nil
        options.fillBackground = background
        return BoardPictureView(
            scene: scene, fitRect: exportRect(scene: scene, dimensions: dimensions), options: options,
            flipX: viewport.flipX, flipY: viewport.flipY, margin: 1,
            overlay: (origin: nil, dimensions: dimensions,
                      color: model.color(of: BoardModel.drawingsLayer), units: model.units))
    }

    /// A one-page PDF at true scale (1 mm on the board is 1 mm on paper).
    static func pdfData(model: BoardModel, viewport: Viewport, scene: BoardScene, dimensions: [LinearDimension],
                        filter: QuartzFilter? = nil, forPrint: Bool = false) throws -> Data {
        let r = exportRect(scene: scene, dimensions: dimensions)
        let pointsPerMM: CGFloat = 72 / 25.4
        let size = CGSize(width: CGFloat(r.width) * pointsPerMM, height: CGFloat(r.height) * pointsPerMM)
        let content = picture(model: model, viewport: viewport, scene: scene, dimensions: dimensions, background: !forPrint)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        let data = NSMutableData()
        var ok = false
        renderer.render { renderSize, draw in
            var box = CGRect(origin: .zero, size: renderSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            let filtered = filter?.apply(to: ctx) ?? false
            draw(ctx)
            if filtered { filter?.remove(from: ctx) }
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        guard ok else { throw ExportError.renderFailed }
        return data as Data
    }

    static func pngData(model: BoardModel, viewport: Viewport, scene: BoardScene, dimensions: [LinearDimension],
                        pixelsPerMM: CGFloat, alpha: Bool) throws -> Data {
        let r = exportRect(scene: scene, dimensions: dimensions)
        let size = CGSize(width: CGFloat(r.width) * pixelsPerMM, height: CGFloat(r.height) * pixelsPerMM)
        let content = picture(model: model, viewport: viewport, scene: scene, dimensions: dimensions, background: !alpha)
            .frame(width: size.width, height: size.height)
        return try png(of: content)
    }

    static func vectorOptions(model: BoardModel, viewport: Viewport, scene: BoardScene,
                              dimensions: [LinearDimension]) -> ExportOptions {
        let drawn = model.drawnLayers
        var o = ExportOptions(layers: scene.drawOrder.filter { drawn.contains($0) },
                              colors: model.renderColors.mapValues(\.rgba))
        o.showZoneFills = model.showZoneFills
        o.showVias = model.showVias
        o.showComponents = model.showComponents
        o.flipX = viewport.flipX
        o.flipY = viewport.flipY
        if !dimensions.isEmpty {
            o.margin = 12
            o.dimensions = dimensions.map { (dimension: $0, label: model.units.format($0.length)) }
            if let c = NSColor(model.color(of: BoardModel.drawingsLayer)).usingColorSpace(.sRGB) {
                o.dimensionColor = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
            }
        }
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
            options.showComponents = model.showComponents
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

    static func writeUSD(_ mesh: Mesh3D, images: [NSImage], to url: URL, kind: USDKind) throws {
        let scn = SCNScene()
        scn.rootNode.addChildNode(sceneNode(mesh, images: images))
        switch kind {
        case .usdz:
            guard scn.write(to: url, options: nil, delegate: nil, progressHandler: nil) else { throw ExportError.writeFailed }
        case .usd, .usda, .usdc:
            guard MDLAsset.canExportFileExtension(kind.rawValue) else { throw ExportError.writeFailed }
            try MDLAsset(scnScene: scn).export(to: url)
        }
    }

    /// The mesh as a SceneKit node, one child per material.
    static func sceneNode(_ mesh: Mesh3D, images: [NSImage], lighting: SCNMaterial.LightingModel = .physicallyBased) -> SCNNode {
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
            material.lightingModel = lighting
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
        return root
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

/// A label's outline as SVG path data for "text as curves": Helvetica, in mm,
/// starting at x = 0 with the baseline at y = 0 (SVG's y runs down).
private func textOutline(_ text: String, _ height: Double) -> (path: String, width: Double) {
    let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(height), nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    func f(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }
    var d = ""
    let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
    for run in runs {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        for i in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
            let ox = positions[i].x, oy = positions[i].y
            func pt(_ p: CGPoint) -> String { "\(f(p.x + ox)) \(f(-(p.y + oy)))" }
            glyph.applyWithBlock { el in
                let e = el.pointee
                switch e.type {
                case .moveToPoint: d += "M" + pt(e.points[0])
                case .addLineToPoint: d += "L" + pt(e.points[0])
                case .addQuadCurveToPoint: d += "Q" + pt(e.points[0]) + " " + pt(e.points[1])
                case .addCurveToPoint: d += "C" + pt(e.points[0]) + " " + pt(e.points[1]) + " " + pt(e.points[2])
                case .closeSubpath: d += "Z"
                @unknown default: break
                }
            }
        }
    }
    return (d, Double(width))
}
