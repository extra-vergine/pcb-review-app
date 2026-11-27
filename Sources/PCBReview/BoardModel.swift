import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KiCadKit

/// One tab above the canvas: every active layer, or a single layer.
enum ViewTab: Hashable {
    case all
    case layer(String)

    var layerName: String? {
        if case .layer(let n) = self { return n }
        return nil
    }
}

/// A corner of the board outline that can serve as the origin.
enum OriginCorner: String, CaseIterable {
    case lowerLeft = "lower left", lowerRight = "lower right", upperRight = "upper right", upperLeft = "upper left"

    var next: OriginCorner {
        switch self {
        case .lowerLeft: return .lowerRight
        case .lowerRight: return .upperRight
        case .upperRight: return .upperLeft
        case .upperLeft: return .lowerLeft
        }
    }

    func point(in b: Rect) -> Point {
        switch self {
        case .lowerLeft: return Point(b.minX, b.maxY)
        case .lowerRight: return Point(b.maxX, b.maxY)
        case .upperRight: return Point(b.maxX, b.minY)
        case .upperLeft: return Point(b.minX, b.minY)
        }
    }
}

/// A blue dashed guide line placed by dragging from a ruler.
struct Guide: Identifiable, Equatable {
    enum Axis { case horizontal, vertical }
    let id = UUID()
    /// Horizontal guides sit at a board Y, vertical guides at a board X (mm).
    var axis: Axis
    var position: Double
}

/// App state: the open board, which layers are active, the view options and the selection.
@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var input: ReviewInput?
    @Published private(set) var url: URL?
    @Published private(set) var scene: BoardScene?

    /// Layers switched on with the green check marks.
    @Published var visibleLayers: Set<String> = []
    @Published var tab: ViewTab = .all {
        didSet { if oldValue != tab { revalidateSelection() } }
    }

    @Published var showZoneFills = true
    @Published var showVias = true
    @Published var showComponents = true {
        didSet { if !showComponents { revalidateSelection() } }
    }
    @Published var showOrigin = true
    @Published var showRulers = true
    @Published var units: LengthUnit = .mm

    /// The origin corner picked by clicking the origin marker; nil means the board file's own origin.
    @Published var originCorner: OriginCorner?
    @Published var guides: [Guide] = []
    /// The guide being dragged out of a ruler, drawn but not yet placed.
    @Published var pendingGuide: Guide?
    private var draggedGuide: UUID?

    // Dimensions, drawn on the User.Drawings layer. Turning one on also activates that layer.
    @Published var showBoardWidth = false { didSet { if showBoardWidth { activateDrawings() } } }
    @Published var showBoardHeight = false { didSet { if showBoardHeight { activateDrawings() } } }
    @Published var showHoleSpacingX = false { didSet { if showHoleSpacingX { activateDrawings() } } }
    @Published var showHoleSpacingY = false { didSet { if showHoleSpacingY { activateDrawings() } } }

    /// Colours the user picked for layers, remembered between launches.
    @Published private(set) var customColors: [String: Color] = BoardModel.loadColors()

    @Published var selection: BoardItem? {
        didSet { updateHighlight() }
    }
    /// Paths of everything on the selected item's net, for highlighting.
    @Published private(set) var highlight: NetHighlight?
    @Published var errorMessage: String?
    /// Bumped to ask the canvas to zoom to fit.
    @Published var fitRequest = 0

    static let drawingsLayer = "Dwgs.User"

    /// Paper, orientation and margins from File › Page Setup.
    let printInfo: NSPrintInfo = {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = .landscape
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        return info
    }()

    var windowTitle: String { url?.lastPathComponent ?? "PCB Review" }

    var layerList: [LayerInfo] { scene?.layers ?? [] }

    /// "All active layers" first, then one tab per layer: copper top to bottom, then the others.
    var tabs: [ViewTab] {
        [.all] + layerList.map { .layer($0.name) }
    }

    func title(of tab: ViewTab) -> String {
        switch tab {
        case .all: return "All active layers"
        case .layer(let name): return layerList.first { $0.name == name }?.displayName ?? name
        }
    }

    func selectTab(number n: Int) {
        let t = tabs
        if n >= 1, n <= t.count { tab = t[n - 1] }
    }

    /// Switches the layer of tab `n` (1-based) off, or back on if it is off.
    /// For the "All active layers" tab this does nothing.
    func toggleTabLayer(number n: Int) {
        let t = tabs
        guard n >= 1, n <= t.count, let layer = t[n - 1].layerName else { return }
        toggle(layer)
    }

    /// The layers actually drawn: every active layer on the "All" tab; on a
    /// layer tab that layer plus the outline and drawings if active.
    var drawnLayers: Set<String> {
        switch tab {
        case .all:
            return visibleLayers
        case .layer(let name):
            return Set([name]).union(visibleLayers.intersection(["Edge.Cuts", Self.drawingsLayer]))
        }
    }

    var anyDimensionShown: Bool { showBoardWidth || showBoardHeight || showHoleSpacingX || showHoleSpacingY }

    /// The dimensions to draw, if the drawings layer is shown.
    var dimensions: [LinearDimension] {
        guard let board = input?.board, drawnLayers.contains(Self.drawingsLayer) else { return [] }
        var out: [LinearDimension] = []
        if showBoardWidth, let d = board.overallDimension(.horizontal) { out.append(d) }
        if showBoardHeight, let d = board.overallDimension(.vertical) { out.append(d) }
        if showHoleSpacingX { out += board.mountingHoleDimensions(.horizontal) }
        if showHoleSpacingY { out += board.mountingHoleDimensions(.vertical) }
        return out
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kicad_pcb") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a KiCad board file"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        do {
            let loaded = try ReviewInput.load(boardAt: url)
            let scene = BoardScene(board: loaded.board)
            self.input = loaded
            self.url = url
            self.scene = scene
            self.selection = nil
            self.originCorner = nil
            self.guides = []
            self.tab = .all
            self.visibleLayers = Set(scene.layers.filter(\.visibleByDefault).map(\.name))
            if anyDimensionShown { activateDrawings() }
            self.fitRequest += 1
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            errorMessage = "\(url.lastPathComponent): \(error)"
        }
    }

    func isActive(_ layer: String) -> Bool { visibleLayers.contains(layer) }

    // MARK: Origin

    /// The origin for rulers and coordinates: the picked corner, or the board's drill/place origin.
    var userOrigin: Point {
        guard let board = input?.board else { return Point(0, 0) }
        if let corner = originCorner, let b = board.outlineBounds { return corner.point(in: b) }
        return board.userOrigin
    }

    /// Which corner the origin is at, if it is at one.
    var originDescription: String {
        if let c = originCorner { return c.rawValue }
        guard let board = input?.board, let b = board.outlineBounds else { return "board origin" }
        let o = board.userOrigin
        return OriginCorner.allCases.first { $0.point(in: b).distance(to: o) < 0.01 }?.rawValue ?? "board origin"
    }

    /// Moves the origin to the next corner: lower left → lower right → upper right → upper left → …
    func cycleOrigin() {
        guard let board = input?.board, let b = board.outlineBounds else { return }
        if let c = originCorner {
            originCorner = c.next
        } else {
            let o = board.userOrigin
            let current = OriginCorner.allCases.first { $0.point(in: b).distance(to: o) < 0.01 }
            originCorner = current?.next ?? .lowerLeft
        }
    }

    // MARK: Guides

    func clearGuides() {
        guides = []
        pendingGuide = nil
    }

    /// Starts dragging a guide that lies within a few points of `screen`. Returns false if there is none.
    func grabGuide(at screen: CGPoint, transform t: ViewTransform) -> Bool {
        let hit = guides.last { g in
            switch g.axis {
            case .horizontal: return abs(t.screen(Point(0, g.position)).y - screen.y) <= 4
            case .vertical: return abs(t.screen(Point(g.position, 0)).x - screen.x) <= 4
            }
        }
        draggedGuide = hit?.id
        return hit != nil
    }

    func moveGuide(to screen: CGPoint, transform t: ViewTransform) {
        guard let id = draggedGuide, let i = guides.firstIndex(where: { $0.id == id }) else { return }
        let p = t.board(screen)
        guides[i].position = guides[i].axis == .horizontal ? p.y : p.x
    }

    /// Ends a guide drag; dropping a guide back on its ruler removes it.
    func endGuideDrag(at screen: CGPoint, rulerSize: CGFloat) {
        defer { draggedGuide = nil }
        guard showRulers, let id = draggedGuide, let i = guides.firstIndex(where: { $0.id == id }) else { return }
        let onRuler = guides[i].axis == .horizontal ? screen.y < rulerSize : screen.x < rulerSize
        if onRuler { guides.remove(at: i) }
    }

    // MARK: Fit

    /// What zoom to fit shows: the board, plus the dimensions and their labels when shown.
    var fitRect: Rect? {
        guard var r = scene?.bounds else { return nil }
        for d in dimensions {
            switch d.axis {
            case .horizontal:
                r.minY = min(r.minY, d.lineAt - 5); r.maxY = max(r.maxY, d.lineAt + 5)
            case .vertical:
                r.minX = min(r.minX, d.lineAt - 5); r.maxX = max(r.maxX, d.lineAt + 5)
            }
        }
        return r
    }

    // MARK: Layer colours

    func color(of layer: String) -> Color {
        customColors[layer] ?? scene?.color(of: layer) ?? .gray
    }

    func setColor(_ color: Color, for layer: String) {
        customColors[layer] = color
        saveColors()
    }

    func resetColor(for layer: String) {
        customColors[layer] = nil
        saveColors()
    }

    /// Every listed layer's current colour, for drawing.
    var renderColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: layerList.map { ($0.name, color(of: $0.name)) })
    }

    /// The options the canvas draws with right now.
    var renderOptions: RenderOptions {
        RenderOptions(layers: drawnLayers, colors: renderColors, showZoneFills: showZoneFills,
                      showVias: showVias, showComponents: showComponents, highlight: highlight)
    }

    private static let colorsKey = "layerColors"

    private static func loadColors() -> [String: Color] {
        guard let stored = UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: [Double]] else { return [:] }
        var out: [String: Color] = [:]
        for (layer, c) in stored where c.count == 4 {
            out[layer] = Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
        }
        return out
    }

    private func saveColors() {
        var stored: [String: [Double]] = [:]
        for (layer, color) in customColors {
            let rgba = color.rgba
            stored[layer] = [rgba.r, rgba.g, rgba.b, rgba.a]
        }
        UserDefaults.standard.set(stored, forKey: Self.colorsKey)
    }

    func toggle(_ layer: String) {
        if visibleLayers.contains(layer) { visibleLayers.remove(layer) } else { visibleLayers.insert(layer) }
        revalidateSelection()
    }

    func showOnly(_ predicate: (LayerInfo) -> Bool) {
        visibleLayers = Set(layerList.filter(predicate).map(\.name))
        revalidateSelection()
    }

    func select(at point: Point) {
        guard let board = input?.board else { return }
        var item = board.hitTest(point, visibleLayers: drawnLayers, includeFootprints: showComponents)
        if case .zone? = item, !showZoneFills { item = nil }
        if case .via? = item, !showVias { item = nil }
        selection = item
    }

    private func activateDrawings() {
        visibleLayers.insert(Self.drawingsLayer)
    }

    /// Clears the selection when its layer is no longer drawn.
    private func revalidateSelection() {
        guard let item = selection, let board = input?.board else { return }
        let layers = drawnLayers
        let stillShown: Bool
        switch item {
        case .pad(let f, let p): stillShown = showComponents && board.footprints[f].pads[p].copperLayers.contains { layers.contains($0) }
        case .footprint: stillShown = showComponents
        case .track(let i): stillShown = layers.contains(board.tracks[i].layer)
        case .via(let i): stillShown = board.vias[i].spannedLayers.contains { layers.contains($0) }
        case .zone(let i): stillShown = board.zones[i].layers.contains { layers.contains($0) }
        }
        if !stillShown { selection = nil }
    }

    private func updateHighlight() {
        guard let board = input?.board, let item = selection, let scene else { highlight = nil; return }
        highlight = NetHighlight(net: board.net(of: item), item: item, board: board, scene: scene)
    }
}
