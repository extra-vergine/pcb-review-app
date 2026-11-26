import Foundation

/// A node of a KiCad S-expression file.
///
/// KiCad files are trees of lists such as `(segment (start 1 2) (net "GND"))`.
/// Bare tokens (`segment`, `1`, `yes`) are symbols; quoted tokens are strings.
public enum SExpr: Equatable, Sendable {
    case symbol(String)
    case string(String)
    indirect case list([SExpr])

    /// The text of a symbol or string atom, `nil` for a list.
    public var atom: String? {
        switch self {
        case .symbol(let s), .string(let s): return s
        case .list: return nil
        }
    }

    /// The items of a list, empty for an atom.
    public var items: [SExpr] {
        if case .list(let l) = self { return l }
        return []
    }

    /// The first token of a list, e.g. `segment` for `(segment ...)`.
    public var head: String? {
        guard case .list(let l) = self, let first = l.first, case .symbol(let s) = first else { return nil }
        return s
    }

    /// All direct child lists whose head is `name`.
    public func children(_ name: String) -> [SExpr] {
        items.filter { $0.head == name }
    }

    /// The first direct child list whose head is `name`.
    public func child(_ name: String) -> SExpr? {
        items.first { $0.head == name }
    }

    /// The atom at `index` of this list (index 0 is the head).
    public func atom(at index: Int) -> String? {
        let l = items
        return index < l.count ? l[index].atom : nil
    }

    public func double(at index: Int) -> Double? {
        atom(at: index).flatMap(Double.init)
    }

    /// The atoms after the head, e.g. `["F.Cu", "B.Cu"]` for `(layers "F.Cu" "B.Cu")`.
    public var arguments: [String] {
        items.dropFirst().compactMap(\.atom)
    }

    /// Value of a child like `(width 0.25)` as a double.
    public func value(_ name: String) -> Double? {
        child(name)?.double(at: 1)
    }

    /// Value of a child like `(layer "F.Cu")` as a string.
    public func text(_ name: String) -> String? {
        child(name)?.atom(at: 1)
    }

    /// True for `(name yes)`, and also for a bare `name` symbol flag used by older files.
    public func flag(_ name: String) -> Bool {
        if let c = child(name) {
            let v = c.atom(at: 1)
            return v == nil || v == "yes" || v == "true"
        }
        return items.contains { if case .symbol(let s) = $0 { return s == name } else { return false } }
    }
}

public struct SExprParseError: Error, CustomStringConvertible {
    public let message: String
    public let line: Int
    public var description: String { "line \(line): \(message)" }
}

/// Parses KiCad S-expressions. `allowComments` skips `#` comments, which only
/// `.kicad_dru` files use.
public enum SExprParser {
    public static func parse(_ text: String, allowComments: Bool = false) throws -> [SExpr] {
        let bytes = Array(text.utf8)
        var i = 0
        var line = 1
        var stack: [[SExpr]] = [[]]

        @inline(__always) func isDelimiter(_ b: UInt8) -> Bool {
            b == 0x28 || b == 0x29 || b == 0x22 || b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
        }

        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x0A:
                line += 1; i += 1
            case 0x20, 0x09, 0x0D:
                i += 1
            case 0x23 where allowComments: // '#'
                while i < bytes.count && bytes[i] != 0x0A { i += 1 }
            case 0x28: // '('
                stack.append([]); i += 1
            case 0x29: // ')'
                guard stack.count > 1 else {
                    throw SExprParseError(message: "unbalanced ')'", line: line)
                }
                let done = stack.removeLast()
                stack[stack.count - 1].append(.list(done))
                i += 1
            case 0x22: // '"'
                i += 1
                var out = [UInt8]()
                var closed = false
                while i < bytes.count {
                    let c = bytes[i]
                    if c == 0x5C, i + 1 < bytes.count { // backslash escape
                        let n = bytes[i + 1]
                        switch n {
                        case 0x6E: out.append(0x0A)
                        case 0x74: out.append(0x09)
                        default: out.append(n)
                        }
                        i += 2
                        continue
                    }
                    if c == 0x22 { closed = true; i += 1; break }
                    if c == 0x0A { line += 1 }
                    out.append(c)
                    i += 1
                }
                guard closed else { throw SExprParseError(message: "unterminated string", line: line) }
                stack[stack.count - 1].append(.string(String(decoding: out, as: UTF8.self)))
            default:
                let start = i
                while i < bytes.count && !isDelimiter(bytes[i]) { i += 1 }
                stack[stack.count - 1].append(.symbol(String(decoding: bytes[start..<i], as: UTF8.self)))
            }
        }
        guard stack.count == 1 else {
            throw SExprParseError(message: "\(stack.count - 1) unclosed '('", line: line)
        }
        return stack[0]
    }
}
