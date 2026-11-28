import AppKit
import SwiftUI

/// Settings keys, stored in UserDefaults through @AppStorage.
enum AppSettings {
    static let appearance = "appearance"           // AppearanceChoice
    static let trackpadScroll = "3d.trackpadScroll" // Gesture3D: two-finger swipe on a trackpad
    static let leftDrag = "3d.leftDrag"             // Gesture3D
    static let rightDrag = "3d.rightDrag"           // Gesture3D
    static let middleDrag = "3d.middleDrag"         // Gesture3D
    static let scrollWheel = "3d.scrollWheel"       // Gesture3D: mouse wheel
    static let invertZoom = "3d.invertZoom"         // Bool
    static let zoomSpeed = "3d.zoomSpeed"           // Double, 0.25 ... 4
    static let orbitSpeed = "3d.orbitSpeed"         // Double, 0.25 ... 4
    static let homeView = "3d.homeView"             // HomeView

    static func gesture(_ key: String, default d: Gesture3D) -> Gesture3D {
        UserDefaults.standard.string(forKey: key).flatMap(Gesture3D.init(rawValue:)) ?? d
    }
    static func number(_ key: String, default d: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? d : UserDefaults.standard.double(forKey: key)
    }

    static func applyAppearance() {
        let choice = AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: appearance) ?? "") ?? .system
        NSApp.appearance = choice.nsAppearance
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Where the 3D view's house button (and a double-click on the viewfinder) goes.
enum HomeView: String, CaseIterable, Identifiable {
    case isometric = "Isometric", front = "Front", back = "Back", left = "Left", right = "Right",
         top = "Top", bottom = "Bottom", frontAbove = "Front, from above"
    var id: String { rawValue }

    /// Camera yaw (about the board normal, 0 = from the front) and pitch (up from the board plane), radians.
    var angles: (yaw: Float, pitch: Float) {
        switch self {
        case .isometric: return (.pi / 4, asin(1 / Float(3).squareRoot()))
        case .front: return (0, 0)
        case .back: return (.pi, 0)
        case .left: return (-.pi / 2, 0)
        case .right: return (.pi / 2, 0)
        case .top: return (0, .pi / 2)
        case .bottom: return (0, -.pi / 2)
        case .frontAbove: return (0, 0.85)
        }
    }
}

/// What an input does in the 3D view.
enum Gesture3D: String, CaseIterable, Identifiable {
    case orbit = "Rotate", pan = "Pan", zoom = "Zoom", none = "Nothing"
    var id: String { rawValue }
}

struct SettingsView: View {
    @AppStorage(AppSettings.appearance) private var appearance = AppearanceChoice.system.rawValue
    @AppStorage(AppSettings.trackpadScroll) private var trackpadScroll = Gesture3D.pan.rawValue
    @AppStorage(AppSettings.leftDrag) private var leftDrag = Gesture3D.orbit.rawValue
    @AppStorage(AppSettings.rightDrag) private var rightDrag = Gesture3D.pan.rawValue
    @AppStorage(AppSettings.middleDrag) private var middleDrag = Gesture3D.pan.rawValue
    @AppStorage(AppSettings.scrollWheel) private var scrollWheel = Gesture3D.zoom.rawValue
    @AppStorage(AppSettings.invertZoom) private var invertZoom = false
    @AppStorage(AppSettings.zoomSpeed) private var zoomSpeed = 1.0
    @AppStorage(AppSettings.orbitSpeed) private var orbitSpeed = 1.0
    @AppStorage(AppSettings.homeView) private var homeView = HomeView.isometric.rawValue

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _ in AppSettings.applyAppearance() }
                Text("System follows the Mac's Light or Dark setting.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Home view") {
                    Picker("House button goes to", selection: $homeView) {
                        ForEach(HomeView.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }
                Section("Trackpad") {
                    gesturePicker("Two-finger swipe", $trackpadScroll, [.pan, .orbit, .zoom])
                    Text("Pinch always zooms. ⌥ + two-finger swipe does the other of rotate and pan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Mouse") {
                    gesturePicker("Left button drag", $leftDrag, [.orbit, .pan])
                    gesturePicker("Right button drag", $rightDrag, [.pan, .orbit, .zoom, .none])
                    gesturePicker("Middle button drag", $middleDrag, [.pan, .orbit, .zoom, .none])
                    gesturePicker("Scroll wheel", $scrollWheel, [.zoom, .pan, .orbit])
                    Text("⌥ + left drag pans; ⇧ + left drag zooms.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Speed") {
                    Toggle("Invert zoom direction", isOn: $invertZoom)
                    Slider(value: $zoomSpeed, in: 0.25...4) { Text("Zoom speed") }
                    Slider(value: $orbitSpeed, in: 0.25...4) { Text("Rotate speed") }
                }
            }
            .padding(20)
            .tabItem { Label("3D Input", systemImage: "rotate.3d") }
        }
        .frame(width: 460, height: 480)
    }

    private func gesturePicker(_ title: String, _ value: Binding<String>, _ options: [Gesture3D]) -> some View {
        Picker(title, selection: value) {
            ForEach(options) { Text($0.rawValue).tag($0.rawValue) }
        }
    }
}
