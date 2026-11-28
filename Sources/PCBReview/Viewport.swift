import SwiftUI
import KiCadKit

/// Board-to-screen mapping: scale, offset and optional mirroring per axis.
struct ViewTransform: Equatable {
    /// Pixels per millimetre.
    var scale: CGFloat
    /// Screen position of board coordinate (0, 0).
    var offset: CGSize
    var flipX = false
    var flipY = false

    var sx: CGFloat { flipX ? -scale : scale }
    var sy: CGFloat { flipY ? -scale : scale }

    func screen(_ p: Point) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * sx + offset.width, y: CGFloat(p.y) * sy + offset.height)
    }

    func board(_ s: CGPoint) -> Point {
        Point(Double((s.x - offset.width) / sx), Double((s.y - offset.height) / sy))
    }

    var affine: CGAffineTransform {
        CGAffineTransform(translationX: offset.width, y: offset.height).scaledBy(x: sx, y: sy)
    }

    /// The transform that fits `b` into `size`, centred.
    static func fitting(_ b: Rect, in size: CGSize, margin: CGFloat = 0.9, flipX: Bool = false, flipY: Bool = false) -> ViewTransform {
        guard size.width > 0, size.height > 0, b.width > 0, b.height > 0 else {
            return ViewTransform(scale: 1, offset: .zero, flipX: flipX, flipY: flipY)
        }
        let s = min(size.width / CGFloat(b.width), size.height / CGFloat(b.height)) * margin
        var t = ViewTransform(scale: s, offset: .zero, flipX: flipX, flipY: flipY)
        let cx = CGFloat(b.minX + b.width / 2), cy = CGFloat(b.minY + b.height / 2)
        t.offset = CGSize(width: size.width / 2 - cx * t.sx, height: size.height / 2 - cy * t.sy)
        return t
    }
}

/// Zoom, pan and flip state of the board canvas, kept apart from `BoardModel`
/// so that panning only redraws the canvas, not the side panels.
@MainActor
final class Viewport: ObservableObject {
    @Published var transform = ViewTransform(scale: 4, offset: .zero)
    /// Size of the canvas in points.
    @Published var size: CGSize = .zero
    /// Cursor position on the board, if the cursor is over the canvas.
    @Published var hover: Point?
    /// True while the view shows "zoom to fit": it then refits when the window
    /// changes size (also while the window first opens). Panning or zooming turns it off.
    var autoFit = true

    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 3000

    var scale: CGFloat { transform.scale }
    var flipX: Bool { transform.flipX }
    var flipY: Bool { transform.flipY }

    func toBoard(_ p: CGPoint) -> Point { transform.board(p) }
    func toScreen(_ p: Point) -> CGPoint { transform.screen(p) }

    func pan(by d: CGSize) {
        autoFit = false
        transform.offset.width += d.width
        transform.offset.height += d.height
    }

    /// Zooms keeping the board point under `location` in place.
    func zoom(by factor: CGFloat, at location: CGPoint) {
        autoFit = false
        let newScale = min(max(transform.scale * factor, Self.minScale), Self.maxScale)
        let k = newScale / transform.scale
        var t = transform
        t.offset.width = location.x - (location.x - t.offset.width) * k
        t.offset.height = location.y - (location.y - t.offset.height) * k
        t.scale = newScale
        transform = t
    }

    /// Zooms around the centre of the canvas (for the keyboard shortcuts).
    func zoomCentered(by factor: CGFloat) {
        zoom(by: factor, at: center)
    }

    /// Shows `b`. `auto` keeps it fitted while the window resizes (zoom to fit), and is off for zooming to a finding.
    func fit(_ b: Rect, auto: Bool = true) {
        transform = .fitting(b, in: size, flipX: transform.flipX, flipY: transform.flipY)
        autoFit = auto
    }

    /// Moves the view so that board point `p` is in the centre of the canvas.
    func center(on p: Point) {
        autoFit = false
        let c = center
        transform.offset = CGSize(width: c.x - CGFloat(p.x) * transform.sx, height: c.y - CGFloat(p.y) * transform.sy)
    }

    /// The board area the canvas shows right now.
    var visibleBoardRect: Rect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
        return Rect.enclosing(corners.map(transform.board))
    }

    /// The board point at the centre of the canvas.
    var centerPoint: Point { transform.board(center) }

    /// Mirrors the view, keeping the board point at the centre of the canvas in place.
    func setFlip(x: Bool? = nil, y: Bool? = nil) {
        let keep = transform.board(center)
        var t = transform
        if let x { t.flipX = x }
        if let y { t.flipY = y }
        t.offset = CGSize(width: center.x - CGFloat(keep.x) * t.sx, height: center.y - CGFloat(keep.y) * t.sy)
        transform = t
    }

    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
}
