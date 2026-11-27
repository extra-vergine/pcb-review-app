import SwiftUI
import KiCadKit

/// What to draw and how; shared by the screen, printing and image exports.
struct RenderOptions {
    var layers: Set<String>
    var colors: [String: Color]
    var showZoneFills = true
    var showVias = true
    var highlight: NetHighlight?
    /// Fill the whole canvas with the background colour. Off for printing.
    var fillBackground = true

    static let background = Color(red: 0.07, green: 0.08, blue: 0.09)
    static let substrate = Color(red: 0.11, green: 0.14, blue: 0.13)
    static let via = Color(white: 0.72)
}

enum BoardRenderer {
    /// Draws the board into `ctx` using `t` to map board millimetres to points.
    static func draw(_ scene: BoardScene, in ctx: GraphicsContext, size: CGSize, transform t: ViewTransform, options o: RenderOptions) {
        if o.fillBackground {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RenderOptions.background))
        }
        var c = ctx
        c.concatenate(t.affine)

        c.fill(scene.substrate, with: .color(RenderOptions.substrate))

        let dim: Double = o.highlight?.net == nil ? 1 : 0.45
        var anyCopperDrawn = false
        for layer in scene.drawOrder where o.layers.contains(layer) {
            guard let lp = scene.paths[layer] else { continue }
            let color = o.colors[layer] ?? scene.color(of: layer)
            if layer.hasSuffix(".Cu") { anyCopperDrawn = true }
            if o.showZoneFills { c.fill(lp.zoneFills, with: .color(color.opacity(0.32 * dim))) }
            for g in lp.tracks {
                c.stroke(g.path, with: .color(color.opacity(0.9 * dim)),
                         style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
            }
            c.fill(lp.pads, with: .color(color.opacity(0.95 * dim)))
            c.fill(lp.filledGraphics, with: .color(color.opacity(0.9)))
            for g in lp.graphics {
                c.stroke(g.path, with: .color(color.opacity(0.9)),
                         style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
            }
        }

        if anyCopperDrawn {
            if o.showVias { c.fill(scene.viaPaths, with: .color(RenderOptions.via.opacity(dim))) }
            c.fill(scene.holes, with: .color(RenderOptions.background))
        }

        if let h = o.highlight {
            let glow = Color.white.opacity(0.55)
            for layer in scene.drawOrder where o.layers.contains(layer) {
                guard let lp = h.netPaths[layer] else { continue }
                for g in lp.tracks {
                    c.stroke(g.path, with: .color(glow), style: StrokeStyle(lineWidth: g.width, lineCap: .round, lineJoin: .round))
                }
                c.fill(lp.pads, with: .color(glow))
            }
            if o.showVias && anyCopperDrawn { c.fill(h.viaPaths, with: .color(glow)) }
            c.stroke(h.selectedOutline, with: .color(.cyan),
                     style: StrokeStyle(lineWidth: 2 / t.scale, lineCap: .round, lineJoin: .round))
        }
    }

    /// Origin marker and dimensions, drawn in screen space so text and arrows keep their size.
    static func drawOverlay(in ctx: GraphicsContext, transform t: ViewTransform, origin: Point?,
                            dimensions: [LinearDimension], dimensionColor: Color, units: LengthUnit) {
        for d in dimensions {
            DimensionRenderer.draw(d, in: ctx, color: dimensionColor, units: units, toScreen: t.screen)
        }
        if let origin {
            let o = t.screen(origin)
            var cross = Path()
            cross.move(to: CGPoint(x: o.x - 12, y: o.y)); cross.addLine(to: CGPoint(x: o.x + 12, y: o.y))
            cross.move(to: CGPoint(x: o.x, y: o.y - 12)); cross.addLine(to: CGPoint(x: o.x, y: o.y + 12))
            let ring = Path(ellipseIn: CGRect(x: o.x - 6, y: o.y - 6, width: 12, height: 12))
            let originColor = Color(red: 0.35, green: 0.85, blue: 0.95)
            ctx.stroke(cross, with: .color(originColor), lineWidth: 1.2)
            ctx.stroke(ring, with: .color(originColor), lineWidth: 1.2)
        }
    }
}

/// A non-interactive board picture fitted to its size: used for printing and image exports.
struct BoardPictureView: View {
    let scene: BoardScene
    let fitRect: Rect
    let options: RenderOptions
    var flipX = false
    var flipY = false
    var margin: CGFloat = 0.96
    var overlay: (origin: Point?, dimensions: [LinearDimension], color: Color, units: LengthUnit)?

    var body: some View {
        Canvas { ctx, size in
            let t = ViewTransform.fitting(fitRect, in: size, margin: margin, flipX: flipX, flipY: flipY)
            BoardRenderer.draw(scene, in: ctx, size: size, transform: t, options: options)
            if let ov = overlay {
                BoardRenderer.drawOverlay(in: ctx, transform: t, origin: ov.origin, dimensions: ov.dimensions,
                                          dimensionColor: ov.color, units: ov.units)
            }
        }
    }
}
