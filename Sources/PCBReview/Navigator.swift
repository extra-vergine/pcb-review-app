import AppKit
import SwiftUI
import KiCadKit

/// The 2D viewfinder: a miniature of the board with a frame showing what the
/// canvas shows. Drag to move the view; double-click for zoom to fit and the default layers.
struct NavigatorView: View {
    @EnvironmentObject var model: BoardModel
    @EnvironmentObject var viewport: Viewport
    @State private var dragStart: Point?

    var body: some View {
        GeometryReader { geo in
            let mini = miniTransform(geo.size)
            ZStack {
                NavigatorMiniature(transform: mini)
                NavigatorFrame(transform: mini)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let mini else { return }
                        let start = dragStart ?? viewport.centerPoint
                        if dragStart == nil { dragStart = start }
                        let a = mini.board(g.startLocation), b = mini.board(g.location)
                        viewport.center(on: Point(start.x + b.x - a.x, start.y + b.y - a.y))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.showOnly(\.visibleByDefault)
                model.tab = .all
                model.fitRequest += 1
            })
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
        .help("Drag to move the view. Double-click for zoom to fit and the default layers.")
    }

    private func miniTransform(_ size: CGSize) -> ViewTransform? {
        guard let r = model.scene?.bounds else { return nil }
        return .fitting(r, in: size, margin: 0.9)
    }
}

/// The board drawn small, with every active layer. Redraws only when the model changes.
private struct NavigatorMiniature: View {
    let transform: ViewTransform?
    @EnvironmentObject var model: BoardModel

    var body: some View {
        let scene = model.scene
        var options = model.renderOptions
        options.highlight = nil
        options.fillBackground = false
        options.layers = model.visibleLayers
        return Canvas { ctx, size in
            if let scene, let t = transform { BoardRenderer.draw(scene, in: ctx, size: size, transform: t, options: options) }
        }
    }
}

/// The visible area as a frame. Redraws when the view moves.
private struct NavigatorFrame: View {
    let transform: ViewTransform?
    @EnvironmentObject var viewport: Viewport

    var body: some View {
        let visible = viewport.visibleBoardRect
        return Canvas { ctx, size in
            guard let t = transform, let r = visible else { return }
            let a = t.screen(Point(r.minX, r.minY)), b = t.screen(Point(r.maxX, r.maxY))
            let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                .intersection(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            guard !frame.isNull else { return }
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(frame)
            ctx.fill(outside, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(frame), with: .color(Color(red: 1, green: 0.3, blue: 0.25)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// A small colour square that opens the system colour panel.
struct ColorSwatch: View {
    let color: Color
    let onChange: (Color) -> Void

    var body: some View {
        Button {
            ColorPanelTarget.shared.open(with: color, onChange: onChange)
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}

/// Routes the shared colour panel's changes to the swatch that opened it.
@MainActor
final class ColorPanelTarget: NSObject {
    static let shared = ColorPanelTarget()
    private var onChange: ((Color) -> Void)?

    func open(with color: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(color)
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func changed(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }
}
