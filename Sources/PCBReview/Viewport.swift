import SwiftUI
import KiCadKit

/// Zoom and pan state of the board canvas, kept apart from `BoardModel` so
/// that panning only redraws the canvas, not the side panels.
@MainActor
final class Viewport: ObservableObject {
    /// Pixels per millimetre.
    @Published var scale: CGFloat = 4
    /// Screen position of board coordinate (0, 0).
    @Published var offset: CGSize = .zero
    /// Size of the canvas in points.
    @Published var size: CGSize = .zero
    /// Cursor position on the board, if the cursor is over the canvas.
    @Published var hover: Point?

    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 3000

    func toBoard(_ p: CGPoint) -> Point {
        Point(Double((p.x - offset.width) / scale), Double((p.y - offset.height) / scale))
    }

    func toScreen(_ p: Point) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * scale + offset.width, y: CGFloat(p.y) * scale + offset.height)
    }

    func pan(by d: CGSize) {
        offset.width += d.width
        offset.height += d.height
    }

    /// Zooms keeping the board point under `location` in place.
    func zoom(by factor: CGFloat, at location: CGPoint) {
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let k = newScale / scale
        offset.width = location.x - (location.x - offset.width) * k
        offset.height = location.y - (location.y - offset.height) * k
        scale = newScale
    }

    /// Zooms around the centre of the canvas (for the keyboard shortcuts).
    func zoomCentered(by factor: CGFloat) {
        zoom(by: factor, at: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    func fit(_ b: Rect, margin: CGFloat = 0.9) {
        guard size.width > 0, size.height > 0, b.width > 0, b.height > 0 else { return }
        let s = min(size.width / CGFloat(b.width), size.height / CGFloat(b.height)) * margin
        scale = s
        offset = CGSize(width: size.width / 2 - CGFloat(b.minX + b.width / 2) * s,
                        height: size.height / 2 - CGFloat(b.minY + b.height / 2) * s)
    }
}
