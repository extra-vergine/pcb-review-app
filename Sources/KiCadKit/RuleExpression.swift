import Foundation

/// A small evaluator for the condition strings of `.kicad_dru` rules, such as
/// `A.NetName == 'VPOE' && B.Type == 'Zone'`.
///
/// It understands `A.` and `B.` properties `NetName`, `NetClass`, `Type` and
/// `Layer`, string and number literals, `==`, `!=`, `&&`, `||`, `!` and
/// parentheses. String comparisons ignore case and accept `*` and `?`
/// wildcards, as KiCad's do. Anything else (functions such as
/// `intersectsArea`, other properties) makes `parse` throw, and the rule is
/// reported as not checked rather than guessed.
public indirect enum RuleExpression: Sendable {
    case string(String)
    case number(Double)
    case property(item: String, name: String)
    case not(RuleExpression)
    case and(RuleExpression, RuleExpression)
    case or(RuleExpression, RuleExpression)
    case equal(RuleExpression, RuleExpression)
    case notEqual(RuleExpression, RuleExpression)

    public struct Unsupported: Error, CustomStringConvertible {
        public var description: String
    }

    /// Properties of one item, as the expression sees them.
    public struct Item: Hashable, Sendable {
        public var netName: String?
        public var netClass: String?
        /// `Track`, `Via`, `Pad`, `Zone`, `Text` or `Graphic`.
        public var type: String
        public var layer: String?

        public init(netName: String?, netClass: String?, type: String, layer: String?) {
            self.netName = netName; self.netClass = netClass; self.type = type; self.layer = layer
        }
    }

    static let knownProperties: Set<String> = ["netname", "netclass", "type", "layer"]

    public static func parse(_ text: String) throws -> RuleExpression {
        var p = Parser(tokens: try tokenize(text))
        let e = try p.parseOr()
        guard p.atEnd else { throw Unsupported(description: "unexpected \(p.peek ?? "") in condition") }
        return e
    }

    /// Evaluates the condition for items `a` and (for two-item constraints) `b`.
    /// A property of a missing item makes the comparison false.
    public func evaluate(a: Item, b: Item?) -> Bool {
        truth(value(a: a, b: b))
    }

    private enum Value { case string(String), number(Double), bool(Bool), missing }

    private func truth(_ v: Value) -> Bool {
        switch v {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .missing: return false
        }
    }

    private func value(a: Item, b: Item?) -> Value {
        switch self {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .property(let which, let name):
            guard let item = which == "A" ? a : b else { return .missing }
            let v: String?
            switch name.lowercased() {
            case "netname": v = item.netName
            case "netclass": v = item.netClass
            case "type": v = item.type
            default: v = item.layer
            }
            return v.map(Value.string) ?? .missing
        case .not(let e): return .bool(!truth(e.value(a: a, b: b)))
        case .and(let l, let r): return .bool(truth(l.value(a: a, b: b)) && truth(r.value(a: a, b: b)))
        case .or(let l, let r): return .bool(truth(l.value(a: a, b: b)) || truth(r.value(a: a, b: b)))
        case .equal(let l, let r): return Self.compare(l.value(a: a, b: b), r.value(a: a, b: b)).map(Value.bool) ?? .bool(false)
        case .notEqual(let l, let r): return Self.compare(l.value(a: a, b: b), r.value(a: a, b: b)).map { .bool(!$0) } ?? .bool(false)
        }
    }

    /// nil when a side is missing: then both `==` and `!=` are false.
    private static func compare(_ l: Value, _ r: Value) -> Bool? {
        switch (l, r) {
        case (.missing, _), (_, .missing): return nil
        case (.string(let x), .string(let y)):
            return NetPattern.wildcard(y.lowercased(), x.lowercased()) || NetPattern.wildcard(x.lowercased(), y.lowercased())
        case (.number(let x), .number(let y)): return abs(x - y) < 1e-9
        case (.bool(let x), .bool(let y)): return x == y
        default: return false
        }
    }

    /// True if the expression reads any property of item B.
    public var usesB: Bool {
        switch self {
        case .string, .number: return false
        case .property(let item, _): return item == "B"
        case .not(let e): return e.usesB
        case .and(let l, let r), .or(let l, let r), .equal(let l, let r), .notEqual(let l, let r): return l.usesB || r.usesB
        }
    }

    // MARK: Parsing

    private static func tokenize(_ s: String) throws -> [String] {
        var out: [String] = []
        let c = Array(s)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "'" || ch == "\"" {
                var j = i + 1
                while j < c.count, c[j] != ch { j += 1 }
                guard j < c.count else { throw Unsupported(description: "unterminated string in condition") }
                out.append("'" + String(c[(i + 1)..<j]))
                i = j + 1
                continue
            }
            if i + 1 < c.count, ["==", "!=", "&&", "||"].contains(String(c[i...(i + 1)])) {
                out.append(String(c[i...(i + 1)])); i += 2; continue
            }
            if "()!".contains(ch) { out.append(String(ch)); i += 1; continue }
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." {
                var j = i
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "." { j += 1 }
                out.append(String(c[i..<j])); i = j
                continue
            }
            throw Unsupported(description: "operator \(ch) is not supported")
        }
        return out
    }

    private struct Parser {
        var tokens: [String]
        var pos = 0
        var atEnd: Bool { pos >= tokens.count }
        var peek: String? { atEnd ? nil : tokens[pos] }
        mutating func next() -> String? { defer { pos += 1 }; return peek }

        mutating func parseOr() throws -> RuleExpression {
            var e = try parseAnd()
            while peek == "||" { _ = next(); e = .or(e, try parseAnd()) }
            return e
        }
        mutating func parseAnd() throws -> RuleExpression {
            var e = try parseUnary()
            while peek == "&&" { _ = next(); e = .and(e, try parseUnary()) }
            return e
        }
        mutating func parseUnary() throws -> RuleExpression {
            if peek == "!" { _ = next(); return .not(try parseUnary()) }
            let l = try parsePrimary()
            if peek == "==" { _ = next(); return .equal(l, try parsePrimary()) }
            if peek == "!=" { _ = next(); return .notEqual(l, try parsePrimary()) }
            return l
        }
        mutating func parsePrimary() throws -> RuleExpression {
            guard let t = next() else { throw Unsupported(description: "condition ends early") }
            if t == "(" {
                let e = try parseOr()
                guard next() == ")" else { throw Unsupported(description: "missing ) in condition") }
                return e
            }
            if t.hasPrefix("'") { return .string(String(t.dropFirst())) }
            if let n = Double(t) { return .number(n) }
            if peek == "(" { throw Unsupported(description: "function \(t)() is not supported") }
            let parts = t.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "A" || parts[0] == "B" else {
                throw Unsupported(description: "\(t) is not supported")
            }
            guard RuleExpression.knownProperties.contains(parts[1].lowercased()) else {
                throw Unsupported(description: "property \(parts[1]) is not supported")
            }
            return .property(item: parts[0], name: parts[1])
        }
    }
}
