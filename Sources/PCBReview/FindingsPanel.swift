import AppKit
import SwiftUI
import KiCadKit

/// The right-hand side: the findings list or the inspector.
struct SidePanelView: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.sidePanel) {
                ForEach(SidePanel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch model.sidePanel {
            case .findings: FindingsPanel()
            case .inspector: InspectorPanel()
            }
        }
    }
}

extension FindingSeverity {
    var color: Color {
        switch self {
        case .error: return Color(red: 0.95, green: 0.25, blue: 0.22)
        case .warning: return Color(red: 0.98, green: 0.68, blue: 0.1)
        case .info: return Color(red: 0.4, green: 0.65, blue: 1)
        }
    }

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// The deterministic check results: KiCad rules and the chosen fab, each in its own section.
struct FindingsPanel: View {
    @EnvironmentObject var model: BoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            Divider()
            if model.report == nil {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Checking the board…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                if let f = model.selectedFinding {
                    Divider()
                    FindingDetail(finding: f)
                        .padding(10)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                Text("Deterministic checks").font(.headline)
                Spacer()
                if model.isChecking { ProgressView().controlSize(.small) }
            }
            .padding(.top, 8)
            Picker("Fab", selection: $model.fabProfileID) {
                Text("KiCad rules only").tag(BoardModel.kicadOnly)
                ForEach(model.fabProfiles) { p in
                    Text("KiCad rules + \(p.name)").tag(p.id)
                }
            }
            if let r = model.report {
                HStack(spacing: 10) {
                    count(r.count(.error), .error)
                    count(r.count(.warning), .warning)
                    count(r.count(.info), .info)
                    Spacer()
                    Text(String(format: "%.1f s", r.seconds)).foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
                Picker("", selection: $model.findingFilter) {
                    ForEach(FindingFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Button(model.drcFindings == nil ? "Cross-check with KiCad DRC" : "Run KiCad DRC Again") { model.runKiCadDRC() }
                    .disabled(model.isRunningDRC)
                    .help("Runs kicad-cli pcb drc on the board file and lists its results in their own section")
                if model.isRunningDRC { ProgressView().controlSize(.small) }
            }
            if let status = model.drcStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func count(_ n: Int, _ s: FindingSeverity) -> some View {
        Label("\(n)", systemImage: s.symbol)
            .foregroundStyle(n == 0 ? Color.secondary : s.color)
            .help("\(n) \(s.title.lowercased())\(n == 1 ? "" : "s")")
    }

    private var list: some View {
        let groups = model.findingGroups
        return List {
            ForEach(groups) { group in
                Section {
                    if group.kinds.isEmpty {
                        Label("No findings", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.kinds) { k in
                        DisclosureGroup {
                            ForEach(k.findings) { f in FindingRow(finding: f) }
                        } label: {
                            HStack {
                                Text(k.kind.title)
                                Spacer()
                                Text("\(k.findings.count)")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(worst(k.findings).color.opacity(0.25)))
                            }
                        }
                    }
                } header: {
                    suiteHeader(group.suite)
                }
            }
            if let r = model.report {
                Section("Rules used") {
                    ForEach(r.applied, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    ForEach(r.profile?.notes ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func suiteHeader(_ suite: CheckSuite) -> some View {
        switch suite {
        case .kicad:
            return Text("KiCad rules: board setup, net classes, custom rules")
        case .fab(_, let name):
            let checked = model.report?.profile?.checked ?? ""
            return Text("\(name) limits, checked \(checked)")
        case .kicadDRC:
            return Text("KiCad's own DRC (kicad-cli), as a cross-check")
        }
    }

    private func worst(_ list: [Finding]) -> FindingSeverity { list.map(\.severity).min() ?? .info }
}

struct FindingRow: View {
    let finding: Finding
    @EnvironmentObject var model: BoardModel

    var body: some View {
        let selected = model.selectedFindingID == finding.id
        Button {
            model.focus(finding)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: finding.severity.symbol)
                    .foregroundStyle(finding.severity.color)
                Text(finding.message)
                    .font(.callout)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What was measured, the limit, and where the limit comes from.
struct FindingDetail: View {
    let finding: Finding
    @EnvironmentObject var model: BoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(finding.severity.title, systemImage: finding.severity.symbol)
                    .foregroundStyle(finding.severity.color)
                    .font(.headline)
                Spacer()
                Button { model.stepFinding(by: -1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous finding (⌘[)")
                Button { model.stepFinding(by: 1) } label: { Image(systemName: "chevron.down") }
                    .help("Next finding (⌘])")
            }
            Text(finding.message).font(.callout).textSelection(.enabled)
            let units = model.units
            let o = model.userOrigin
            InfoSection(title: finding.kind.title, rows: [
                ("Measured", finding.actual.map { units.format($0) } ?? "–"),
                ("Limit", finding.required.map { units.format($0) } ?? "–"),
                ("Layer", finding.layer ?? "–"),
                ("At", "X \(units.format(finding.location.x - o.x, withUnit: false))  Y \(units.format(o.y - finding.location.y, withUnit: false))"),
            ])
            VStack(alignment: .leading, spacing: 3) {
                Text("Rule").font(.headline)
                Text(finding.rule.title).font(.callout)
                if let d = finding.rule.detail {
                    Text(d).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !finding.rule.verified {
                    Label("Value not confirmed word for word on the fab's page", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let s = finding.rule.url, let url = URL(string: s) {
                    Link("Open the fab's page", destination: url).font(.caption)
                }
            }
        }
    }
}

/// Markers for the findings: a dot for each shown finding, a ring and box for the selected one.
enum FindingRenderer {
    static func draw(_ findings: [Finding], selected: Finding?, in ctx: GraphicsContext, transform t: ViewTransform) {
        for f in findings.prefix(3000) where f.kind != .ruleNotChecked {
            let p = t.screen(f.location)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(f.severity.color.opacity(0.85)))
        }
        guard let f = selected, f.kind != .ruleNotChecked else { return }
        let p = t.screen(f.location)
        let a = t.screen(Point(f.area.minX, f.area.minY)), b = t.screen(Point(f.area.maxX, f.area.maxY))
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -4, dy: -4)
        ctx.stroke(Path(box), with: .color(f.severity.color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)), with: .color(.white), lineWidth: 3.5)
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)), with: .color(f.severity.color), lineWidth: 2)
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - 18, y: p.y)); cross.addLine(to: CGPoint(x: p.x - 6, y: p.y))
        cross.move(to: CGPoint(x: p.x + 6, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 18, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - 18)); cross.addLine(to: CGPoint(x: p.x, y: p.y - 6))
        cross.move(to: CGPoint(x: p.x, y: p.y + 6)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 18))
        ctx.stroke(cross, with: .color(f.severity.color), lineWidth: 2)
    }
}
