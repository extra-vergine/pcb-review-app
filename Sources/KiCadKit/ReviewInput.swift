import Foundation

/// A board plus the project and custom-rules files that sit next to it.
public struct ReviewInput: Sendable {
    public var board: Board
    public var project: Project?
    public var customRules: CustomRules?
    /// Files that were expected but missing or unreadable, with the reason.
    public var warnings: [String]

    /// Loads `name.kicad_pcb` and, if present, `name.kicad_pro` and `name.kicad_dru` from the same folder.
    public static func load(boardAt url: URL) throws -> ReviewInput {
        let board = try BoardParser.parse(contentsOf: url)
        var warnings: [String] = []
        if board.version < BoardParser.kicad10Version {
            warnings.append("Board file format \(board.version) is older than KiCad 10; some data may be missing.")
        }
        let base = url.deletingPathExtension()
        let fm = FileManager.default

        var project: Project?
        let pro = base.appendingPathExtension("kicad_pro")
        if fm.fileExists(atPath: pro.path) {
            do { project = try ProjectParser.parse(contentsOf: pro) }
            catch { warnings.append("Could not read \(pro.lastPathComponent): \(error)") }
        } else {
            warnings.append("No \(pro.lastPathComponent) next to the board: net classes and board rules are unknown.")
        }

        var rules: CustomRules?
        let dru = base.appendingPathExtension("kicad_dru")
        if fm.fileExists(atPath: dru.path) {
            do { rules = try CustomRulesParser.parse(contentsOf: dru) }
            catch { warnings.append("Could not read \(dru.lastPathComponent): \(error)") }
        }
        return ReviewInput(board: board, project: project, customRules: rules, warnings: warnings)
    }
}
