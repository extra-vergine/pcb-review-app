import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KiCadKit

/// App state: the open board, which layers are visible, and what is selected.
@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var input: ReviewInput?
    @Published private(set) var url: URL?
    @Published private(set) var scene: BoardScene?
    @Published var visibleLayers: Set<String> = []
    @Published var showZoneFills = true
    @Published var showVias = true
    @Published var selection: BoardItem? {
        didSet { updateHighlight() }
    }
    /// Paths of everything on the selected item's net, for highlighting.
    @Published private(set) var highlight: NetHighlight?
    @Published var errorMessage: String?
    /// Bumped to ask the canvas to zoom to fit.
    @Published var fitRequest = 0

    var windowTitle: String {
        guard let url else { return "PCB Review" }
        return url.lastPathComponent
    }

    /// Layers that have something on them, in a sensible order: copper top to
    /// bottom, then silkscreen, outline and the rest.
    var layerList: [LayerInfo] { scene?.layers ?? [] }

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
            self.visibleLayers = Set(scene.layers.filter(\.visibleByDefault).map(\.name))
            self.fitRequest += 1
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            errorMessage = "\(url.lastPathComponent): \(error)"
        }
    }

    func toggle(_ layer: String) {
        if visibleLayers.contains(layer) { visibleLayers.remove(layer) } else { visibleLayers.insert(layer) }
    }

    func showOnly(_ predicate: (LayerInfo) -> Bool) {
        visibleLayers = Set(layerList.filter(predicate).map(\.name))
    }

    /// Layers the hit test considers: visible ones, minus fills and vias when hidden.
    var pickableLayers: Set<String> { visibleLayers }

    func select(at point: Point) {
        guard let board = input?.board else { return }
        var item = board.hitTest(point, visibleLayers: pickableLayers)
        if case .zone? = item, !showZoneFills { item = nil }
        if case .via? = item, !showVias { item = nil }
        selection = item
    }

    private func updateHighlight() {
        guard let board = input?.board, let item = selection, let scene else { highlight = nil; return }
        let net = board.net(of: item)
        highlight = NetHighlight(net: net, item: item, board: board, scene: scene)
    }
}
