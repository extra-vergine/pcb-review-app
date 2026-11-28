import AppKit
import SwiftUI
import KiCadKit

struct LayerPanel: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        VStack(spacing: 8) {
            if let board = model.input?.board {
                BoardInfoHeader(board: board, fileName: model.url?.lastPathComponent)
                    .padding([.horizontal, .top], 8)
            }
            ScrollView {
                VStack(spacing: 8) { groups }
                    .padding(.horizontal, 8)
            }
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button { model.showOnly { $0.isCopper || $0.name == "Edge.Cuts" } } label: {
                        Text("Copper only").frame(maxWidth: .infinity)
                    }
                    Button { model.showOnly(\.visibleByDefault) } label: {
                        Text("Defaults").frame(maxWidth: .infinity)
                    }
                }
                FlipButtons()
            }
            .controlSize(.large)
            .padding(.horizontal, 8)
            if model.viewMode == .threeD {
                ViewCubeView()
                    .frame(height: 150)
                    .padding(.horizontal, 8)
            }
            NavigatorView()
                .frame(height: 140)
                .padding(.horizontal, 8)
            Picker("", selection: $model.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .help("Switch between the 2D (⌃2) and 3D (⌃3) views")
            .padding([.horizontal, .bottom], 8)
        }
    }

    @ViewBuilder private var groups: some View {
        PanelGroup("Board") {
            Picker("Origin", selection: $model.originCorner) {
                Text("File origin (\(model.fileOriginPlace))").tag(OriginCorner?.none)
                ForEach(OriginCorner.allCases, id: \.self) { c in
                    Text(c.rawValue.capitalized).tag(OriginCorner?.some(c))
                }
            }
            Picker("Board", selection: $model.materialChoice) {
                Text("From file (\(model.fileMaterialName))").tag(BoardModel.fileChoice)
                Divider()
                ForEach(BoardAppearance.materialOptions) { Text($0.label).tag($0.id) }
            }
            Picker("Mask", selection: $model.maskChoice) {
                Text("From file (\(model.fileMaskName))").tag(BoardModel.fileChoice)
                Divider()
                ForEach(BoardAppearance.maskOptions) { Text($0.label).tag($0.id) }
            }
            Picker("Silkscreen", selection: $model.silkChoice) {
                Text("Automatic (to suit the mask)").tag(BoardModel.autoChoice)
                Text("From file (\(model.fileSilkName))").tag(BoardModel.fileChoice)
                Divider()
                ForEach(BoardAppearance.silkOptions) { Text($0.label).tag($0.id) }
            }
        }
        PanelGroup("Copper", hint: "⌥-click: all") {
            ForEach(model.layerList.filter(\.isCopper)) { row($0) }
        }
        PanelGroup("Other layers", hint: "⌥-click: all") {
            ForEach(model.layerList.filter { !$0.isCopper }) { row($0) }
        }
        PanelGroup("Elements", hint: "⌥-click: all") {
            groupToggle("Origin", \.showOrigin, in: Self.elements)
            groupToggle("Rulers (⌘R)", \.showRulers, in: Self.elements)
            groupToggle("Zone fills", \.showZoneFills, in: Self.elements)
            groupToggle("Vias", \.showVias, in: Self.elements)
            groupToggle("Components", \.showComponents, in: Self.elements)
                .help("Pads, footprint graphics and texts, and the 3D models")
            groupToggle("Shadow (3D)", \.showShadow, in: Self.elements)
                .help("A soft shadow under the board in the 3D view")
        }
        PanelGroup("Dimensions", hint: "⌥-click: all") {
            groupToggle("Board, horizontal", \.showBoardWidth, in: Self.dimensions)
            groupToggle("Board, vertical", \.showBoardHeight, in: Self.dimensions)
            groupToggle("Mounting holes, horizontal", \.showHoleSpacingX, in: Self.dimensions)
            groupToggle("Mounting holes, vertical", \.showHoleSpacingY, in: Self.dimensions)
        }
    }

    static let elements: [ReferenceWritableKeyPath<BoardModel, Bool>] =
        [\.showOrigin, \.showRulers, \.showZoneFills, \.showVias, \.showComponents, \.showShadow]
    static let dimensions: [ReferenceWritableKeyPath<BoardModel, Bool>] =
        [\.showBoardWidth, \.showBoardHeight, \.showHoleSpacingX, \.showHoleSpacingY]

    /// A checkbox that switches the whole group when ⌥ is held.
    private func groupToggle(_ title: String, _ key: ReferenceWritableKeyPath<BoardModel, Bool>,
                             in group: [ReferenceWritableKeyPath<BoardModel, Bool>]) -> some View {
        let m = model
        return Toggle(title, isOn: Binding(
            get: { m[keyPath: key] },
            set: { value in
                if NSEvent.modifierFlags.contains(.option) {
                    for k in group where m[keyPath: k] != value { m[keyPath: k] = value }
                } else {
                    m[keyPath: key] = value
                }
            }))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A layer row: a green check mark activates or deactivates the layer;
    /// clicking the colour swatch opens the colour picker for it.
    private func row(_ layer: LayerInfo) -> some View {
        let active = model.isActive(layer.name)
        return HStack(spacing: 10) {
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    model.setGroup(copper: layer.isCopper, active: !active)
                } else {
                    model.toggle(layer.name)
                }
            } label: {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? Color.green : Color.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help((active ? "Deactivate \(layer.name)" : "Activate \(layer.name)") + ". ⌥-click for all \(layer.isCopper ? "copper" : "other") layers.")

            ColorSwatch(color: model.color(of: layer.name)) { model.setColor($0, for: layer.name) }
            .help("Choose a colour for \(layer.name)")
            .contextMenu {
                Button("Reset Colour") { model.resetColor(for: layer.name) }
            }

            Button {
                model.toggle(layer.name)
            } label: {
                HStack {
                    Text(layer.displayName)
                        .lineLimit(1)
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A titled group on a subtle rounded background, to separate the panel's areas.
struct PanelGroup<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.16)))
    }
}

/// The most important facts about the board, at the top of the left panel.
struct BoardInfoHeader: View {
    let board: Board
    let fileName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(board.title ?? fileName ?? "Board")
                .font(.headline).lineLimit(2)
                .help(fileName ?? "")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                info("Revision", board.revision ?? "–")
                info("Date", board.date ?? "–")
                info("Format", "KiCad \(board.generatorVersion ?? "?") (\(board.version))")
                info("Size", board.outlineBounds.map { String(format: "%.2f × %.2f mm", $0.width, $0.height) } ?? "–")
                info("Thickness", board.thickness.map { String(format: "%.2f mm", $0) } ?? "–")
                info("Copper layers", "\(board.copperLayers.count)")
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.16)))
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// Tabs above the canvas: all active layers, then each copper layer. ⌘1, ⌘2, … select them.
struct LayerTabBar: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        HStack(spacing: 0) {
            if model.viewMode == .twoD {
                tabs
            } else {
                Text("3D view: drag to turn, scroll or pinch to zoom, two fingers or ⌥-drag to pan")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            }
        }
        .background(.bar)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.tabs.enumerated()), id: \.offset) { index, tab in
                    let selected = model.tab == tab
                    let inactive = tab.layerName.map { !model.isActive($0) } ?? false
                    Button {
                        model.tab = tab
                    } label: {
                        HStack(spacing: 6) {
                            if let name = tab.layerName {
                                RoundedRectangle(cornerRadius: 2).fill(model.color(of: name)).frame(width: 10, height: 10)
                            }
                            Text(model.title(of: tab))
                                .strikethrough(inactive)
                                .foregroundStyle(inactive ? Color.secondary : Color.primary)
                            if index < 9 {
                                Text("⌘\(index + 1)").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(index < 9 && tab.layerName != nil
                          ? "⌘\(index + 1) shows this tab, ⌥⌘\(index + 1) switches its layer \(inactive ? "on" : "off")"
                          : model.title(of: tab))
                    .contextMenu {
                        if let name = tab.layerName {
                            Button(inactive ? "Activate Layer" : "Deactivate Layer") { model.toggle(name) }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }
}

/// Flip X / Flip Y toggles. A separate view so only it redraws when the viewport changes.
struct FlipButtons: View {
    @EnvironmentObject var viewport: Viewport

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { viewport.flipX }, set: { viewport.setFlip(x: $0) })) {
                Label("Flip X", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .frame(maxWidth: .infinity)
            }
            .help("Mirror left–right (⇧⌘X)")
            Toggle(isOn: Binding(get: { viewport.flipY }, set: { viewport.setFlip(y: $0) })) {
                Label("Flip Y", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    .frame(maxWidth: .infinity)
            }
            .help("Mirror top–bottom (⇧⌘Y)")
        }
        .toggleStyle(.button)
        .labelStyle(.titleAndIcon)
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
