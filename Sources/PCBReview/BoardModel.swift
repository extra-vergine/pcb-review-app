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

/// A point of the board outline that can serve as the origin: a corner or the centre.
enum OriginCorner: String, CaseIterable {
    case lowerLeft = "lower left", lowerRight = "lower right", center = "centre", upperRight = "upper right", upperLeft = "upper left"

    /// The cycle is file origin → lower left → lower right → centre → upper right → upper left → file origin;
    /// nil stands for the board file's own origin.
    var next: OriginCorner? {
        switch self {
        case .lowerLeft: return .lowerRight
        case .lowerRight: return .center
        case .center: return .upperRight
        case .upperRight: return .upperLeft
        case .upperLeft: return nil
        }
    }

    func point(in b: Rect) -> Point {
        switch self {
        case .lowerLeft: return Point(b.minX, b.maxY)
        case .lowerRight: return Point(b.maxX, b.maxY)
        case .center: return Point((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2)
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

enum ViewMode: String, CaseIterable {
    case twoD = "2D", threeD = "3D"
}

/// Colours for the board preview: solder mask, base material, silkscreen and copper finish.
struct BoardLook: Equatable {
    var mask: RGBA
    var material: RGBA
    var silk: RGBA
    var finish: RGBA
    var hasMask: Bool
}

/// Which panel the right-hand side shows.
enum SidePanel: String, CaseIterable {
    case findings = "Findings", inspector = "Inspector"
}

enum FindingFilter: String, CaseIterable {
    case all = "All", errors = "Errors", warnings = "Warnings"

    func includes(_ f: Finding) -> Bool {
        switch self {
        case .all: return true
        case .errors: return f.severity == .error
        case .warnings: return f.severity == .warning
        }
    }
}

/// One section of the findings list.
struct FindingGroup: Identifiable {
    struct Kind: Identifiable {
        var kind: CheckKind
        var findings: [Finding]
        var id: CheckKind { kind }
    }
    var suite: CheckSuite
    var kinds: [Kind]
    var id: CheckSuite { suite }
}

/// Asks the canvas to show an area; the serial makes repeated requests for the same area distinct.
struct FocusRequest: Equatable {
    var rect: Rect
    var serial: Int
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
    /// A shadow under the board in the 3D view.
    @Published var showShadow = UserDefaults.standard.object(forKey: "3d.shadow") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showShadow, forKey: "3d.shadow") }
    }
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

    // MARK: Design checks state

    /// The fab profiles bundled with the app.
    let fabProfiles = FabProfiles.bundled()
    /// The fab to check against, or `kicadOnly`. Remembered between launches.
    @Published var fabProfileID: String = UserDefaults.standard.string(forKey: "fabProfile") ?? "jlcpcb" {
        didSet {
            UserDefaults.standard.set(fabProfileID, forKey: "fabProfile")
            if oldValue != fabProfileID { runChecks() }
        }
    }
    static let kicadOnly = "kicad"
    @Published private(set) var report: CheckReport?
    @Published private(set) var isChecking = false
    private var checkGeneration = 0
    @Published var selectedFindingID: Int?
    @Published var findingFilter: FindingFilter = .all
    @Published var sidePanel: SidePanel = .findings
    @Published var focusRequest: FocusRequest?

    // MARK: View mode and board look

    @Published var viewMode: ViewMode = .twoD
    /// "file" for the colour in the board file, else a `BoardAppearance.maskOptions` id.
    @Published var maskChoice: String = UserDefaults.standard.string(forKey: "maskChoice") ?? "file" {
        didSet {
            UserDefaults.standard.set(maskChoice, forKey: "maskChoice")
            if silkChoice == Self.autoChoice { clearSilkColors() }
        }
    }
    /// "file" for the material in the board file, else a `BoardAppearance.materialOptions` id.
    @Published var materialChoice: String = UserDefaults.standard.string(forKey: "materialChoice") ?? "file" {
        didSet { UserDefaults.standard.set(materialChoice, forKey: "materialChoice") }
    }

    /// "auto" (what the fab prints on the chosen mask), "file", or a `BoardAppearance.silkOptions` id.
    @Published var silkChoice: String = UserDefaults.standard.string(forKey: "silkChoice") ?? "auto" {
        didSet {
            UserDefaults.standard.set(silkChoice, forKey: "silkChoice")
            clearSilkColors()
        }
    }

    /// A colour picked by hand for a silkscreen layer gives way to the Silkscreen menu.
    private func clearSilkColors() {
        guard customColors["F.SilkS"] != nil || customColors["B.SilkS"] != nil else { return }
        customColors["F.SilkS"] = nil
        customColors["B.SilkS"] = nil
        saveColors()
    }

    /// The canvas and 3D background.
    @Published var backgroundColor: Color = BoardModel.loadBackground() {
        didSet {
            guard let c = NSColor(backgroundColor).usingColorSpace(.sRGB) else { return }
            UserDefaults.standard.set([Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)], forKey: "backgroundColor")
        }
    }

    private static func loadBackground() -> Color {
        guard let c = UserDefaults.standard.array(forKey: "backgroundColor") as? [Double], c.count == 3 else { return RenderOptions.background }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1)
    }

    func resetBackground() {
        backgroundColor = RenderOptions.background
        UserDefaults.standard.removeObject(forKey: "backgroundColor")
    }

    /// Selects a component by its reference (from a click in the 3D view) and shows it in the inspector.
    func selectComponent(reference: String?) {
        guard let reference, let i = input?.board.footprints.firstIndex(where: { $0.reference == reference }) else {
            selection = nil
            return
        }
        selection = .footprint(i)
        sidePanel = .inspector
    }

    static let fileChoice = "file"
    static let autoChoice = "auto"

    /// The colours the board is previewed in.
    var look: BoardLook {
        let board = input?.board
        let maskOption = BoardAppearance.maskOptions.first { $0.id == maskChoice }
        let mask = maskOption?.color ?? board?.fileMaskColor ?? BoardAppearance.maskOptions[0].color
        let hasMask = maskOption?.id != "none"
        let material = BoardAppearance.materialOptions.first { $0.id == materialChoice }?.color
            ?? BoardAppearance.materialColor(board?.fileCoreMaterial)
        // Automatic: fabs print black silkscreen on light masks (white, yellow), white on the rest.
        let white = RGBA(0.95, 0.95, 0.93), black = RGBA(0.08, 0.08, 0.08)
        var silk: RGBA
        if let s = BoardAppearance.silkOptions.first(where: { $0.id == silkChoice }) {
            silk = s.color
        } else if silkChoice == Self.fileChoice {
            silk = board?.fileSilkColor ?? white
        } else {
            let luminance = 0.2126 * mask.r + 0.7152 * mask.g + 0.0722 * mask.b
            silk = hasMask && luminance > 0.45 ? black : white
        }
        return BoardLook(mask: mask, material: material, silk: silk,
                         finish: BoardAppearance.finishColor(board?.copperFinish), hasMask: hasMask)
    }

    /// The mask colour the file sets, for the menu, e.g. "Black".
    var fileMaskName: String { input?.board.stackup.first { $0.name == "F.Mask" }?.color ?? "not set" }
    var fileSilkName: String { input?.board.stackup.first { $0.name == "F.SilkS" }?.color ?? "not set" }
    var fileMaterialName: String { input?.board.fileCoreMaterial ?? "not set" }
    /// Findings from KiCad's own DRC (`kicad-cli`), nil until it has run for this board.
    @Published private(set) var drcFindings: [Finding]?
    @Published private(set) var isRunningDRC = false
    @Published private(set) var drcStatus: String?

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
            self.report = nil
            self.selectedFindingID = nil
            self.drcFindings = nil
            self.drcStatus = nil
            runChecks()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            errorMessage = "\(url.lastPathComponent): \(error)"
        }
    }

    func isActive(_ layer: String) -> Bool { visibleLayers.contains(layer) }

    // MARK: Design checks

    var fabProfile: FabProfile? { fabProfiles.first { $0.id == fabProfileID } }

    /// Runs the deterministic checks in the background and publishes the report.
    func runChecks() {
        guard let input else { return }
        let profile = fabProfile
        checkGeneration += 1
        let generation = checkGeneration
        isChecking = true
        Task.detached(priority: .userInitiated) {
            let report = DesignChecker(input: input, profile: profile).run()
            await MainActor.run {
                guard generation == self.checkGeneration else { return }
                self.report = report
                self.isChecking = false
                if let id = self.selectedFindingID, id < BoardModel.drcIDBase, id >= report.findings.count { self.selectedFindingID = nil }
            }
        }
    }

    /// The findings shown in the list, grouped the way the list shows them:
    /// KiCad rules first, then the fab; within each, by kind of check.
    var findingGroups: [FindingGroup] {
        guard let report else { return [] }
        let shown = allFindings.filter { findingFilter.includes($0) }
        var suites: [CheckSuite] = [.kicad]
        if let p = report.profile { suites.append(.fab(id: p.id, name: p.name)) }
        if drcFindings != nil { suites.append(.kicadDRC) }
        return suites.map { suite in
            let mine = shown.filter { $0.suite == suite }
            let kinds = CheckKind.allCases.compactMap { kind -> FindingGroup.Kind? in
                let list = mine.filter { $0.kind == kind }
                return list.isEmpty ? nil : FindingGroup.Kind(kind: kind, findings: list)
            }
            return FindingGroup(suite: suite, kinds: kinds)
        }
    }

    /// The shown findings in list order, for next and previous.
    var orderedFindings: [Finding] { findingGroups.flatMap { $0.kinds.flatMap(\.findings) } }

    /// This app's findings, then KiCad DRC's (whose ids start at `drcIDBase`).
    var allFindings: [Finding] { (report?.findings ?? []) + (drcFindings ?? []) }
    static let drcIDBase = 1_000_000

    var selectedFinding: Finding? {
        guard let id = selectedFindingID else { return nil }
        if id >= Self.drcIDBase {
            guard let d = drcFindings, id - Self.drcIDBase < d.count else { return nil }
            return d[id - Self.drcIDBase]
        }
        guard let r = report, id < r.findings.count else { return nil }
        return r.findings[id]
    }

    // MARK: KiCad DRC cross-check

    /// Where kicad-cli is installed, if it is.
    static let kicadCLI: String? = [
        "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli",
        "/Applications/KiCad.app/Contents/MacOS/kicad-cli",
        "/opt/homebrew/bin/kicad-cli",
        "/usr/local/bin/kicad-cli",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs `kicad-cli pcb drc` on the open file and shows its results as a third section.
    func runKiCadDRC() {
        guard let url, let board = input?.board else { return }
        guard let cli = Self.kicadCLI else {
            drcStatus = "kicad-cli was not found. Install KiCad in /Applications to use the cross-check."
            return
        }
        isRunningDRC = true
        drcStatus = "Running KiCad DRC…"
        let idBase = Self.drcIDBase
        Task.detached(priority: .userInitiated) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("pcbreview-drc-\(UUID().uuidString).json")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = KiCadDRCReport.arguments(board: url, output: out)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var findings: [Finding]?
            var message: String
            do {
                try process.run()
                let log = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let json = try? Data(contentsOf: out) {
                    findings = try KiCadDRCReport.findings(from: json, board: board)
                    message = "KiCad DRC: \(findings?.count ?? 0) items"
                } else {
                    let text = String(decoding: log, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    message = "KiCad DRC wrote no report (exit \(process.terminationStatus)): \(text.suffix(300))"
                }
            } catch {
                message = "Could not run kicad-cli: \(error)"
            }
            try? FileManager.default.removeItem(at: out)
            let result = findings?.enumerated().map { i, f -> Finding in
                var f = f
                f.id = idBase + i
                return f
            }
            let status = message
            await MainActor.run {
                guard self.url == url else { return }
                self.isRunningDRC = false
                self.drcStatus = status
                if let result { self.drcFindings = result }
            }
        }
    }

    /// Selects a finding, makes its layer and items visible and zooms to it.
    func focus(_ f: Finding) {
        selectedFindingID = f.id
        if let layer = f.layer {
            visibleLayers.insert(layer)
            if let t = tab.layerName, t != layer { tab = .all }
        }
        for item in f.items {
            switch item {
            case .pad, .footprint: showComponents = true
            case .zone: showZoneFills = true
            case .via: showVias = true
            case .track: break
            }
        }
        selection = f.items.first
        // Show the items with some room around them, at least 3 mm across.
        var r = f.area
        let w = max(r.width, 3), h = max(r.height, 3)
        let c = Point((r.minX + r.maxX) / 2, (r.minY + r.maxY) / 2)
        r = Rect(minX: c.x - w * 0.75, minY: c.y - h * 0.75, maxX: c.x + w * 0.75, maxY: c.y + h * 0.75)
        focusRequest = FocusRequest(rect: r, serial: (focusRequest?.serial ?? 0) + 1)
    }

    /// Moves to the next (or previous) finding in the list.
    func stepFinding(by delta: Int) {
        let list = orderedFindings
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedFindingID }
        let next = current.map { ($0 + delta + list.count) % list.count } ?? (delta > 0 ? 0 : list.count - 1)
        sidePanel = .findings
        focus(list[next])
    }

    /// The findings as plain text, for pasting into a message or a note.
    var findingsText: String {
        guard let report else { return "" }
        var lines = ["Design checks for \(url?.lastPathComponent ?? "board"): \(report.count(.error)) errors, \(report.count(.warning)) warnings, \(report.count(.info)) notes"]
        lines += report.applied.map { "Using \($0)" }
        for group in findingGroups {
            lines.append("")
            lines.append("== \(group.suite.title) ==")
            for k in group.kinds {
                lines.append("\(k.kind.title) (\(k.findings.count))")
                for f in k.findings {
                    lines.append(String(format: "  [%@] (%.3f, %.3f) ", f.severity.title, f.location.x, f.location.y) + f.message + " — " + f.rule.title)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func copyFindings() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(findingsText, forType: .string)
    }

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
        guard input?.board != nil else { return "file origin" }
        return "file origin (\(fileOriginPlace))"
    }

    /// Where the file's own origin sits: a corner or the centre of the board, or its coordinates.
    var fileOriginPlace: String {
        guard let board = input?.board else { return "not set" }
        let o = board.userOrigin
        if let b = board.outlineBounds,
           let c = OriginCorner.allCases.first(where: { $0.point(in: b).distance(to: o) < 0.01 }) {
            return c.rawValue
        }
        if board.auxAxisOrigin == nil && board.gridOrigin == nil { return "not set: page corner" }
        return "at " + units.format(o.x, withUnit: false) + ", " + units.format(o.y)
    }

    /// Moves the origin along the cycle: file origin → lower left → lower right → centre → upper right → upper left → file origin.
    func cycleOrigin() {
        guard input?.board.outlineBounds != nil else { return }
        if let c = originCorner {
            originCorner = c.next
        } else {
            originCorner = .lowerLeft
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
        if let c = customColors[layer] { return c }
        if layer == "F.SilkS" || layer == "B.SilkS" {
            let s = look.silk
            return Color(.sRGB, red: s.r, green: s.g, blue: s.b, opacity: 1)
        }
        return scene?.color(of: layer) ?? .gray
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
        let l = look
        let base = l.hasMask ? l.mask : l.material
        let substrate = Color(.sRGB, red: base.r * 0.42 + 0.03, green: base.g * 0.42 + 0.03, blue: base.b * 0.42 + 0.03, opacity: 1)
        var o = RenderOptions(layers: drawnLayers, colors: renderColors, showZoneFills: showZoneFills,
                              showVias: showVias, showComponents: showComponents, highlight: highlight,
                              substrateColor: substrate)
        o.backgroundColor = backgroundColor
        return o
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

    /// Switches every copper layer (or every other layer) on or off at once.
    func setGroup(copper: Bool, active: Bool) {
        for l in layerList where l.isCopper == copper {
            if active { visibleLayers.insert(l.name) } else { visibleLayers.remove(l.name) }
        }
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
        if item != nil { sidePanel = .inspector }
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
