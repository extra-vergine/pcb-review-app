import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KiCadKit

@main
struct PCBReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BoardModel()
    @StateObject private var viewport = Viewport()

    var body: some Scene {
        WindowGroup("PCB Review") {
            ContentView()
                .environmentObject(model)
                .environmentObject(viewport)
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
            CommandGroup(replacing: .newItem) {
                Button("Open Board…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            ViewCommands(model: model, viewport: viewport)
        }
    }
}

/// View menu items: zoom, rulers, selection and the layer tabs (⌘1, ⌘2, …).
struct ViewCommands: Commands {
    @ObservedObject var model: BoardModel
    let viewport: Viewport

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { viewport.zoomCentered(by: 1.25) }
                .keyboardShortcut("+")
            Button("Zoom Out") { viewport.zoomCentered(by: 0.8) }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { model.fitRequest += 1 }
                .keyboardShortcut("0")
            Divider()
            Button(model.showRulers ? "Hide Rulers" : "Show Rulers") { model.showRulers.toggle() }
                .keyboardShortcut("r")
            Button("Switch Units (\(model.units.next.rawValue))") { model.units = model.units.next }
            Divider()
            Button("Clear Selection") { model.selection = nil }
                .keyboardShortcut(.escape, modifiers: [])
        }
        CommandMenu("Layers") {
            ForEach(Array(model.tabs.prefix(9).enumerated()), id: \.offset) { index, tab in
                Button(model.title(of: tab)) { model.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
    }
}

/// Makes the app behave like a normal app (Dock icon, key window) when started
/// from `swift run`, which launches a bare executable rather than an .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
                        BoardCanvasView(board: input.board)
                    }
                    .frame(minWidth: 400)
                    InspectorPanel()
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
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
