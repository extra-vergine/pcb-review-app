import Foundation
import KiCadKit

// Prints a summary of a KiCad board and its project settings.
// Usage: kicad-inspect path/to/board.kicad_pcb

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: kicad-inspect <board.kicad_pcb>\n".data(using: .utf8)!)
    exit(2)
}

do {
    let input = try ReviewInput.load(boardAt: URL(fileURLWithPath: args[1]))
    let b = input.board
    print("\(b.title ?? "(untitled)")  rev \(b.revision ?? "-")  format \(b.version)  KiCad \(b.generatorVersion ?? "?")")
    if let r = b.outlineBounds {
        let thickness = b.thickness.map { "\($0)" } ?? "?"
        print(String(format: "Outline: %.2f x %.2f mm", r.width, r.height) + ", thickness \(thickness) mm")
    }
    let copper = b.copperLayers.map { layer -> String in
        if let n = layer.userName { return "\(layer.name) (\(n))" }
        return layer.name
    }
    print("Copper: " + copper.joined(separator: ", "))
    print("Footprints \(b.footprints.count), pads \(b.pads.count), tracks \(b.tracks.count), vias \(b.vias.count), zones \(b.zones.count), nets \(b.nets.count)")

    if let p = input.project {
        print("\nNet classes:")
        for nc in p.netClasses.sorted(by: { $0.priority < $1.priority }) {
            let members = b.nets.filter { p.resolveNetClass(for: $0).effective == nc.name }
            print("  \(nc.name): clearance \(nc.clearance ?? 0), track \(nc.trackWidth ?? 0), \(members.count) nets")
        }
        let unmatched = p.netClassPatterns.filter { pat in !b.nets.contains { NetPattern.matches(pattern: pat.pattern, name: $0) } }
        if !unmatched.isEmpty {
            print("  Patterns that match no net: " + unmatched.map { "\($0.pattern) -> \($0.netClass)" }.joined(separator: ", "))
        }
    }
    if let r = input.customRules {
        print("\nCustom rules (\(r.rules.count)): " + r.rules.map(\.name).joined(separator: ", "))
    }
    for w in input.warnings { print("warning: \(w)") }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
