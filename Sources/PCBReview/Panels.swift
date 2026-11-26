import SwiftUI
import KiCadKit

struct LayerPanel: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        List {
            Section("Copper") {
                ForEach(model.layerList.filter(\.isCopper)) { row($0) }
            }
            Section("Other layers") {
                ForEach(model.layerList.filter { !$0.isCopper }) { row($0) }
            }
            Section("Show") {
                Toggle("Zone fills", isOn: $model.showZoneFills)
                Toggle("Vias", isOn: $model.showVias)
            }
            Section {
                HStack {
                    Button("Copper only") { model.showOnly { $0.isCopper || $0.name == "Edge.Cuts" } }
                    Button("Defaults") { model.showOnly(\.visibleByDefault) }
                }
                .controlSize(.small)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ layer: LayerInfo) -> some View {
        Toggle(isOn: Binding(
            get: { model.visibleLayers.contains(layer.name) },
            set: { _ in model.toggle(layer.name) }
        )) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(layer.color)
                    .frame(width: 12, height: 12)
                Text(layer.displayName)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
    }
}

struct InspectorPanel: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let input = model.input {
                    if let item = model.selection {
                        SelectionDetails(item: item, input: input)
                    } else {
                        BoardSummary(input: input)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

/// A titled group of label/value rows.
struct InfoSection: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.1).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                .font(.callout)
            }
        }
    }
}

func mm(_ v: Double?) -> String {
    guard let v else { return "–" }
    return String(format: "%.3f mm", v)
}

struct BoardSummary: View {
    let input: ReviewInput

    var body: some View {
        let b = input.board
        VStack(alignment: .leading, spacing: 14) {
            InfoSection(title: b.title ?? "Board", rows: [
                ("Revision", b.revision ?? "–"),
                ("Date", b.date ?? "–"),
                ("Format", "\(b.version) (KiCad \(b.generatorVersion ?? "?"))"),
                ("Size", b.outlineBounds.map { String(format: "%.2f × %.2f mm", $0.width, $0.height) } ?? "–"),
                ("Thickness", mm(b.thickness)),
                ("Copper layers", "\(b.copperLayers.count)"),
            ])
            InfoSection(title: "Contents", rows: [
                ("Footprints", "\(b.footprints.count)"),
                ("Pads", "\(b.pads.count)"),
                ("Tracks", "\(b.tracks.count)"),
                ("Vias", "\(b.vias.count)"),
                ("Zones", "\(b.zones.filter { !$0.isRuleArea }.count)"),
                ("Rule areas", "\(b.zones.filter(\.isRuleArea).count)"),
                ("Nets", "\(b.nets.count)"),
            ])
            if let p = input.project {
                InfoSection(title: "Net classes", rows: p.netClasses.sorted { $0.priority < $1.priority }.map { nc -> (String, String) in
                    let count = b.nets.filter { p.resolveNetClass(for: $0).effective == nc.name }.count
                    return (nc.name, "\(count) nets · \(String(format: "%.2f", nc.clearance ?? 0)) mm clr")
                })
            }
            if let r = input.customRules, !r.rules.isEmpty {
                InfoSection(title: "Custom rules", rows: r.rules.map { rule in
                    (rule.name, rule.constraints.map(\.type).joined(separator: ", "))
                })
            }
            if !input.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Warnings").font(.headline)
                    ForEach(input.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                }
            }
            Text("Click an item on the board to inspect it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct SelectionDetails: View {
    let item: BoardItem
    let input: ReviewInput

    var body: some View {
        let b = input.board
        VStack(alignment: .leading, spacing: 14) {
            switch item {
            case .pad(let f, let p):
                let fp = b.footprints[f], pad = fp.pads[p]
                InfoSection(title: "Pad \(fp.reference).\(pad.number)", rows: [
                    ("Type", "\(pad.kind.rawValue), \(pad.shape.rawValue)"),
                    ("Size", String(format: "%.3f × %.3f mm", pad.size.width, pad.size.height)),
                    ("Drill", pad.drill.map { d in d.slotHeight.map { String(format: "%.3f × %.3f mm slot", d.diameter, $0) } ?? mm(d.diameter) } ?? "–"),
                    ("Position", position(pad.position)),
                    ("Rotation", String(format: "%.1f°", pad.rotation)),
                    ("Layers", pad.copperLayers.joined(separator: ", ")),
                ])
                netSection(pad.net)
                footprintSection(fp)
            case .footprint(let f):
                footprintSection(b.footprints[f])
            case .track(let i):
                let t = b.tracks[i]
                InfoSection(title: t.isArc ? "Track arc" : "Track", rows: [
                    ("Width", mm(t.width)),
                    ("Layer", t.layer),
                    ("Length", mm(length(t.centerline))),
                    ("Start", position(t.start)),
                    ("End", position(t.end)),
                ])
                netSection(t.net)
            case .via(let i):
                let v = b.vias[i]
                InfoSection(title: "Via", rows: [
                    ("Type", v.kind.rawValue),
                    ("Diameter", mm(v.size)),
                    ("Drill", mm(v.drill)),
                    ("Annular ring", mm(v.annularRing)),
                    ("Layers", "\(v.endLayers.joined(separator: " → ")) (\(v.spannedLayers.count))"),
                    ("Position", position(v.position)),
                ])
                netSection(v.net)
            case .zone(let i):
                let z = b.zones[i]
                InfoSection(title: "Zone \(z.name ?? "")", rows: [
                    ("Layers", z.layers.joined(separator: ", ")),
                    ("Min width", mm(z.minThickness)),
                    ("Pad clearance", mm(z.clearance)),
                    ("Fill islands", "\(z.filledPolygons.count)"),
                ])
                netSection(z.net)
            }
        }
    }

    @ViewBuilder
    private func netSection(_ net: String?) -> some View {
        if let net {
            let b = input.board
            let tracks = b.tracks.filter { $0.net == net }
            let resolution = input.project?.resolveNetClass(for: net)
            let nc = resolution.flatMap { input.project?.netClass(named: $0.effective) }
            InfoSection(title: "Net", rows: [
                ("Name", net),
                ("Net class", resolution.map { $0.matched.isEmpty ? "\($0.effective) (no pattern matched)" : $0.effective } ?? "–"),
                ("Class clearance", mm(nc?.clearance)),
                ("Class track width", mm(nc?.trackWidth)),
                ("Pads", "\(b.pads.filter { $0.net == net }.count)"),
                ("Tracks", "\(tracks.count), \(String(format: "%.1f", tracks.reduce(0) { $0 + length($1.centerline) })) mm"),
                ("Vias", "\(b.vias.filter { $0.net == net }.count)"),
                ("Track widths", Set(tracks.map(\.width)).sorted().map { String(format: "%.2f", $0) }.joined(separator: ", ")),
            ])
        } else {
            InfoSection(title: "Net", rows: [("Name", "none")])
        }
    }

    private func footprintSection(_ fp: Footprint) -> some View {
        InfoSection(title: "Footprint \(fp.reference)", rows: [
            ("Value", fp.value),
            ("Library", fp.libraryID),
            ("Side", fp.isBottom ? "Bottom" : "Top"),
            ("Position", position(fp.position)),
            ("Rotation", String(format: "%.1f°", fp.rotation)),
            ("Pads", "\(fp.pads.count)"),
            ("Sheet", fp.sheetName ?? "–"),
        ])
    }

    private func position(_ p: Point) -> String { String(format: "%.3f, %.3f", p.x, p.y) }

    private func length(_ pts: [Point]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
}
