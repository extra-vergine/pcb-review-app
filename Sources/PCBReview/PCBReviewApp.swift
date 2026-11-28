import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KiCadKit

@main
struct PCBReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BoardModel()
    @StateObject private var viewport = Viewport()
    @StateObject private var threeD = ThreeDController()

    var body: some Scene {
        WindowGroup("PCB Review") {
            ContentView()
                .environmentObject(model)
                .environmentObject(viewport)
                .environmentObject(threeD)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    // `swift run PCBReview path/to/board.kicad_pcb` opens that board.
                    let args = CommandLine.arguments.dropFirst().filter { $0.hasSuffix(".kicad_pcb") }
                    if model.input == nil, let path = args.first {
                        model.open(URL(fileURLWithPath: path))
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About PCB Review") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "PCB Review",
                        .applicationVersion: "0.3",
                        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© René Nessler",
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Board…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .importExport) {
                Menu("Export") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.menuTitle) { Exporter.export(format, model: model, viewport: viewport) }
                    }
                }
                .disabled(model.input == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Page Setup…") { Exporter.pageSetup(model: model) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Print…") { Exporter.print(model: model, viewport: viewport) }
                    .keyboardShortcut("p")
                    .disabled(model.input == nil)
            }
            ViewCommands(model: model, viewport: viewport, threeD: threeD)
            CommandGroup(after: .sidebar) {
                Button("2D View") { model.viewMode = .twoD }
                    .keyboardShortcut("2", modifiers: .control)
                Button("3D View") { model.viewMode = .threeD }
                    .keyboardShortcut("3", modifiers: .control)
                Divider()
            }
            CommandMenu("Checks") {
                Button("Next Finding") { model.stepFinding(by: 1) }
                    .keyboardShortcut("]")
                Button("Previous Finding") { model.stepFinding(by: -1) }
                    .keyboardShortcut("[")
                Divider()
                Button("Run Checks Again") { model.runChecks() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Copy Findings as Text") { model.copyFindings() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView()
        }
    }
}

extension ThreeDArea {
    /// The same zoom keys as the 2D canvas, for any keyboard layout:
    /// ⌘ + numpad plus, ⌘⇧1 and any ⌘ "+" zoom in; ⌘ + numpad minus zooms out.
    fileprivate func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let controller = controller
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.contains(.command), !mods.contains(.option), !mods.contains(.control) else { return event }
            let keypadPlus: UInt16 = 69, keypadMinus: UInt16 = 78, digitOne: UInt16 = 18
            if event.keyCode == keypadPlus || (event.keyCode == digitOne && mods.contains(.shift))
                || event.charactersIgnoringModifiers == "+" || event.characters == "+" {
                controller.zoom(by: 0.8)
                return nil
            }
            if event.keyCode == keypadMinus {
                controller.zoom(by: 1.25)
                return nil
            }
            return event
        }
    }
}

/// View menu items: zoom, rulers, selection and the layer tabs (⌘1, ⌘2, …).
struct ViewCommands: Commands {
    @ObservedObject var model: BoardModel
    let viewport: Viewport
    let threeD: ThreeDController

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // ⌘ + numpad plus and ⌘⇧1 also zoom in; the canvas key handler catches those.
            Button("Zoom In") {
                if model.viewMode == .threeD { threeD.zoom(by: 0.8) } else { viewport.zoomCentered(by: 1.25) }
            }
            .keyboardShortcut("+")
            Button("Zoom Out") {
                if model.viewMode == .threeD { threeD.zoom(by: 1.25) } else { viewport.zoomCentered(by: 0.8) }
            }
            .keyboardShortcut("-")
            Button("Zoom to Fit") {
                if model.viewMode == .threeD { threeD.fit() } else { model.fitRequest += 1 }
            }
            .keyboardShortcut("0")
            Divider()
            Button("Flip X (Mirror Left–Right)") { viewport.setFlip(x: !viewport.flipX) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Flip Y (Mirror Top–Bottom)") { viewport.setFlip(y: !viewport.flipY) }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Button(model.showRulers ? "Hide Rulers" : "Show Rulers") { model.showRulers.toggle() }
                .keyboardShortcut("r")
            Button("Switch Units (\(model.units.next.rawValue))") { model.units = model.units.next }
            Divider()
            Button("Clear All Guides") { model.clearGuides() }
                .disabled(model.guides.isEmpty)
            Button("Next Origin") { model.cycleOrigin() }
            Divider()
            Button("Clear Selection") { model.selection = nil; model.selectedFindingID = nil }
                .keyboardShortcut(.escape, modifiers: [])
        }
        CommandMenu("Layers") {
            ForEach(Array(model.tabs.prefix(9).enumerated()), id: \.offset) { index, tab in
                Button("Show \(model.title(of: tab))") { model.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            // ⌥⌘ + tab number switches that tab's layer off (and on again).
            ForEach(Array(model.tabs.prefix(9).enumerated()), id: \.offset) { index, tab in
                if let name = tab.layerName {
                    Button("\(model.isActive(name) ? "Deactivate" : "Activate") \(model.title(of: tab))") {
                        model.toggleTabLayer(number: index + 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
            }
            Divider()
            Toggle("Show Components", isOn: $model.showComponents)
        }
    }
}

/// Makes the app behave like a normal app (Dock icon, key window) when started
/// from `swift run`, which launches a bare executable rather than an .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyAppearance()
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        Group {
            if let input = model.input {
                HSplitView {
                    LayerPanel()
                        .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)
                    VStack(spacing: 0) {
                        LayerTabBar()
                        Divider()
                        if model.viewMode == .twoD {
                            BoardCanvasView(board: input.board)
                        } else {
                            ThreeDArea()
                        }
                    }
                    .frame(minWidth: 400)
                    SidePanelView()
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                }
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle(model.windowTitle)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "kicad_pcb" else { return }
                DispatchQueue.main.async { model.open(url) }
            }
            return true
        }
        .alert("Could not open board", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The 3D view, rebuilt when the board, its look, the layers or the options change.
struct ThreeDArea: View {
    @EnvironmentObject var model: BoardModel
    @EnvironmentObject var controller: ThreeDController
    @EnvironmentObject var viewport: Viewport
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Board3DView(controller: controller)
                .scaleEffect(x: controller.mirrorX ? -1 : 1, y: controller.mirrorY ? -1 : 1)
            if model.showRulers {
                RulersView(origin: model.userOrigin)
                    .environmentObject(controller.rulerViewport)
            }
            VStack(alignment: .leading, spacing: 2) {
                if model.showRulers && !controller.rulersExact {
                    Text("Rulers are exact in the top view with the orthographic camera (eye button).")
                }
                if let s = controller.modelStatus { Text(s) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(model.showRulers ? BoardCanvasView.rulerSize + 6 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .onAppear {
            let m = model
            controller.onPickComponent = { m.selectComponent(reference: $0) }
            controller.load(model)
            controller.setMirror(x: viewport.flipX, y: viewport.flipY)
            installKeyMonitor()
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
        }
        .onChange(of: viewport.flipX) { _ in controller.setMirror(x: viewport.flipX, y: viewport.flipY) }
        .onChange(of: viewport.flipY) { _ in controller.setMirror(x: viewport.flipX, y: viewport.flipY) }
        .onChange(of: model.look) { _ in controller.load(model) }
        .onChange(of: model.showComponents) { _ in controller.load(model) }
        .onChange(of: model.url) { _ in controller.load(model) }
        .onChange(of: model.visibleLayers) { _ in controller.load(model) }
        .onChange(of: model.showZoneFills) { _ in controller.load(model) }
        .onChange(of: model.showVias) { _ in controller.load(model) }
        .onChange(of: model.showOrigin) { _ in controller.load(model) }
        .onChange(of: model.originCorner) { _ in controller.load(model) }
        .onChange(of: model.showShadow) { _ in controller.load(model) }
        .onChange(of: model.showReflection) { _ in controller.load(model) }
        .onChange(of: model.dimensions) { _ in controller.load(model) }
        .onChange(of: model.units) { _ in controller.load(model) }
        .onChange(of: model.backgroundColor) { _ in controller.load(model) }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a KiCad board to review")
                .font(.title3)
            Text("Choose a .kicad_pcb file, or drop one here. The .kicad_pro and .kicad_dru next to it are read too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Open Board…") { model.showOpenPanel() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
