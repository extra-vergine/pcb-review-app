import AppKit
import CoreText
import SwiftUI
import KiCadKit

/// Board texts as filled outlines in board coordinates (mm, Y down).
/// TrueType texts use the outlines KiCad cached in the file. KiCad's own stroke
/// font is not available here, so stroke texts are drawn with the system font,
/// sized so capitals are as tall as in KiCad.
enum TextOutlines {
    static func path(for t: BoardText) -> Path {
        var path = Path()
        if !t.renderCache.isEmpty {
            // Outlines and holes may come in any winding; make holes wind against
            // their outline so a plain (non-zero) fill keeps them open.
            let polys = t.renderCache
            for (i, original) in polys.enumerated() {
                guard let probe = original.first else { continue }
                let depth = polys.indices.filter { $0 != i && contains(polys[$0], probe) }.count
                let wantPositive = depth % 2 == 0
                let poly = (signedArea(original) > 0) == wantPositive ? original : Array(original.reversed())
                guard let first = poly.first else { continue }
                path.move(to: first.cg)
                for p in poly.dropFirst() { path.addLine(to: p.cg) }
                path.closeSubpath()
            }
            return path
        }
        let text = t.text.replacingOccurrences(of: "\\n", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return path }
        let height = t.height ?? 1
        let width = t.width ?? height
        let ratio = (t.thickness ?? height * 0.15) / max(height, 0.01)
        let weight: NSFont.Weight = t.bold || ratio >= 0.22 ? .bold : ratio >= 0.17 ? .semibold : ratio >= 0.12 ? .medium : .regular
        let base = NSFont.systemFont(ofSize: 10, weight: weight) as CTFont
        let capHeight = max(CTFontGetCapHeight(base), 1)
        let size = 10 * CGFloat(height) / capHeight
        var font = CTFontCreateCopyWithAttributes(base, size, nil, nil)
        if t.italic, let italic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) { font = italic }

        let lines = text.components(separatedBy: "\n")
        let lineStep = CGFloat(height) * 1.62
        let xScale = CGFloat(width / height)
        let block = CGFloat(lines.count - 1) * lineStep
        // Baseline of the first line, in text space (y down, anchor at 0, 0).
        let firstBaseline: CGFloat
        switch t.justifyV {
        case -1: firstBaseline = CGFloat(height)
        case 1: firstBaseline = -block
        default: firstBaseline = CGFloat(height) / 2 - block / 2
        }

        // Footprint texts stay readable, as in KiCad.
        var angle = t.rotation
        if t.footprintReference != nil {
            angle = angle.truncatingRemainder(dividingBy: 360)
            if angle < 0 { angle += 360 }
            if angle > 90 && angle <= 270 { angle -= 180 }
        }
        let rad = CGFloat(-angle * .pi / 180)
        var toBoard = CGAffineTransform(translationX: CGFloat(t.position.x), y: CGFloat(t.position.y)).rotated(by: rad)
        if t.mirrored { toBoard = toBoard.scaledBy(x: -1, y: 1) }

        for (i, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)) * xScale
            let x0: CGFloat = t.justifyH == -1 ? 0 : t.justifyH == 1 ? -lineWidth : -lineWidth / 2
            let baseline = firstBaseline + CGFloat(i) * lineStep
            for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                let runFont = runFont(run) ?? font
                for g in 0..<count {
                    guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[g], nil) else { continue }
                    // Glyph space is y up; flip it and place the glyph on its baseline.
                    let place = CGAffineTransform(a: xScale, b: 0, c: 0, d: -1,
                                                  tx: x0 + positions[g].x * xScale, ty: baseline - positions[g].y)
                    path.addPath(Path(glyph), transform: place.concatenating(toBoard))
                }
            }
        }
        return path
    }

    static func signedArea(_ p: [Point]) -> Double {
        var a = 0.0
        for i in p.indices {
            let q = p[(i + 1) % p.count]
            a += p[i].x * q.y - q.x * p[i].y
        }
        return a / 2
    }

    static func contains(_ poly: [Point], _ pt: Point) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > pt.y) != (b.y > pt.y), pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func runFont(_ run: CTRun) -> CTFont? {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        guard let value = attrs[kCTFontAttributeName as String] else { return nil }
        return (value as! CTFont)
    }
}
