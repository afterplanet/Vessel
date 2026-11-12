import Foundation
import Yams

/// Reads SatNOGS telemetry definitions, which are written in Kaitai Struct, without generating code.
/// They arrive from the internet, so they're only ever data here: nothing in one can run, and the
/// limits below stop a bad one tying up the app.
enum KaitaiError: Error { case unsupported(String), parse(String), endOfData, invalid(String), tooDeep }

final class KaitaiAttr {
    var id = ""
    var type: Any?
    var size: String?
    var sizeEos = false
    var terminator: Int?
    var includeTerminator = false
    var consume = true
    var contents: [UInt8]?
    var condition: String?
    var repeatKind: String?
    var repeatExpr: String?
    var repeatUntil: String?
    var process: String?
    var value: String?
    var pos: String?
    var valid: Any?
    var enumName: String?
}

final class KaitaiType {
    let id: String
    weak var outer: KaitaiType?
    var seq: [KaitaiAttr] = []
    var instances: [String: KaitaiAttr] = [:]
    var types: [String: KaitaiType] = [:]
    var enums: [String: [String: Int]] = [:]
    var params: [String] = []
    var bigEndian: Bool?
    var bitsLittle: Bool?

    init(id: String, outer: KaitaiType?) {
        self.id = id
        self.outer = outer
    }

    func find(_ name: String) -> KaitaiType? {
        if let t = types[name] { return t }
        return outer?.find(name)
    }

    func findEnum(_ name: String) -> [String: Int]? {
        if let e = enums[name] { return e }
        return outer?.findEnum(name)
    }

    var isBigEndian: Bool { bigEndian ?? outer?.isBigEndian ?? true }
    var isBitsLittle: Bool { bitsLittle ?? outer?.isBitsLittle ?? false }
}

indirect enum KaitaiValue {
    case int(Int)
    case float(Double)
    case bool(Bool)
    case string(String)
    case bytes([UInt8])
    case array([KaitaiValue])
    case object(KaitaiObject)
    /// A number with a meaning given by the definition: reads as the word, and calculates as the number.
    case named(Int, String)

    var plain: KaitaiValue {
        if case .named(let i, _) = self { return .int(i) }
        return self
    }

    var display: String? {
        switch self {
        case .int(let i): return String(i)
        case .float(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(format: "%.4g", d)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .bytes(let b): return b.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .array(let a): return a.compactMap(\.display).joined(separator: ", ")
        case .object: return nil
        case .named(_, let word): return word
        }
    }
}

final class KaitaiStream {
    let bytes: [UInt8]
    var pos = 0
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var eof: Bool { pos >= bytes.count && bitCount == 0 }

    func align() { bitCount = 0; bitBuffer = 0 }

    func read(_ n: Int) throws -> [UInt8] {
        align()
        guard n >= 0, pos + n <= bytes.count else { throw KaitaiError.endOfData }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }

    func readInt(_ n: Int, bigEndian: Bool) throws -> UInt64 {
        let b = try read(n)
        return (bigEndian ? b : b.reversed()).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Least significant bit first, for the few definitions that ask for it.
    func readBitsLittle(_ n: Int) throws -> UInt64 {
        var out: UInt64 = 0
        for i in 0..<n {
            if bitCount == 0 {
                guard pos < bytes.count else { throw KaitaiError.endOfData }
                bitBuffer = UInt64(bytes[pos])
                pos += 1
                bitCount = 8
            }
            out |= (bitBuffer & 1) << UInt64(i)
            bitBuffer >>= 1
            bitCount -= 1
        }
        return out
    }

    /// Most significant bit first, which is what most definitions use.
    func readBits(_ n: Int) throws -> UInt64 {
        var out: UInt64 = 0
        for _ in 0..<n {
            if bitCount == 0 {
                guard pos < bytes.count else { throw KaitaiError.endOfData }
                bitBuffer = UInt64(bytes[pos])
                pos += 1
                bitCount = 8
            }
            bitCount -= 1
            out = out << 1 | ((bitBuffer >> UInt64(bitCount)) & 1)
        }
        return out
    }
}

final class KaitaiObject {
    let type: KaitaiType
    /// Children keep their parents alive while values are read from them, and nothing outlives a decode.
    let parent: KaitaiObject?
    private let givenRoot: KaitaiObject?
    let io: KaitaiStream
    var values: [String: KaitaiValue] = [:]
    var computing = Set<String>()

    init(type: KaitaiType, parent: KaitaiObject?, root: KaitaiObject?, io: KaitaiStream) {
        self.type = type
        self.parent = parent
        givenRoot = root
        self.io = io
    }

    var root: KaitaiObject { givenRoot ?? self }
}

/// Expressions, in the small language definitions use for sizes, conditions and calculated values.
indirect enum KaitaiExpr {
    case int(Int)
    case float(Double)
    case string(String)
    case bool(Bool)
    case name(String)
    case enumValue(String, String)
    case array([KaitaiExpr])
    case unary(String, KaitaiExpr)
    case binary(String, KaitaiExpr, KaitaiExpr)
    case ternary(KaitaiExpr, KaitaiExpr, KaitaiExpr)
    case member(KaitaiExpr, String)
    case call(KaitaiExpr, String, [KaitaiExpr])
    case index(KaitaiExpr, KaitaiExpr)
}

struct KaitaiExprParser {
    private enum Token: Equatable {
        case int(Int), float(Double), string(String), name(String), symbol(String)
    }
    private var tokens: [Token] = []
    private var at = 0

    static func parse(_ text: String) throws -> KaitaiExpr {
        var p = KaitaiExprParser()
        p.tokens = try tokenize(text)
        let e = try p.ternary()
        guard p.at == p.tokens.count else { throw KaitaiError.parse(text) }
        return e
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var out: [Token] = []
        let c = Array(text)
        var i = 0
        let two = ["==", "!=", "<=", ">=", "<<", ">>", "::"]
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch.isNumber {
                var j = i
                if ch == "0", i + 1 < c.count, c[i + 1] == "x" || c[i + 1] == "b" {
                    let radix = c[i + 1] == "x" ? 16 : 2
                    j = i + 2
                    while j < c.count, c[j].isHexDigit || c[j] == "_" { j += 1 }
                    let digits = String(c[(i + 2)..<j]).replacingOccurrences(of: "_", with: "")
                    guard let v = UInt64(digits, radix: radix) else { throw KaitaiError.parse(text) }
                    out.append(.int(Int(truncatingIfNeeded: v)))
                    i = j
                    continue
                }
                var isFloat = false
                while j < c.count, c[j].isNumber || c[j] == "_" || (c[j] == "." && j + 1 < c.count && c[j + 1].isNumber) || ((c[j] == "e" || c[j] == "E") && j + 1 < c.count && (c[j + 1].isNumber || c[j + 1] == "-")) || (c[j] == "-" && (c[j - 1] == "e" || c[j - 1] == "E")) {
                    if c[j] == "." || c[j] == "e" || c[j] == "E" { isFloat = true }
                    j += 1
                }
                let digits = String(c[i..<j]).replacingOccurrences(of: "_", with: "")
                if isFloat {
                    guard let v = Double(digits) else { throw KaitaiError.parse(text) }
                    out.append(.float(v))
                } else {
                    guard let v = Int(digits) else { throw KaitaiError.parse(text) }
                    out.append(.int(v))
                }
                i = j
                continue
            }
            if ch.isLetter || ch == "_" {
                var j = i
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                out.append(.name(String(c[i..<j])))
                i = j
                continue
            }
            if ch == "\"" || ch == "'" {
                var j = i + 1
                var v = ""
                while j < c.count, c[j] != ch {
                    if c[j] == "\\", ch == "\"", j + 1 < c.count {
                        j += 1
                        switch c[j] {
                        case "n": v.append("\n")
                        case "r": v.append("\r")
                        case "t": v.append("\t")
                        case "0": v.append("\0")
                        default: v.append(c[j])
                        }
                    } else {
                        v.append(c[j])
                    }
                    j += 1
                }
                guard j < c.count else { throw KaitaiError.parse(text) }
                out.append(.string(v))
                i = j + 1
                continue
            }
            if i + 1 < c.count, two.contains(String(c[i...(i + 1)])) {
                out.append(.symbol(String(c[i...(i + 1)])))
                i += 2
                continue
            }
            guard "+-*/%&|^~<>?:()[].,".contains(ch) else { throw KaitaiError.parse(text) }
            out.append(.symbol(String(ch)))
            i += 1
        }
        return out
    }

    private var peek: Token? { at < tokens.count ? tokens[at] : nil }

    private mutating func take(_ symbol: String) -> Bool {
        if peek == .symbol(symbol) { at += 1; return true }
        return false
    }

    private mutating func takeName(_ name: String) -> Bool {
        if peek == .name(name) { at += 1; return true }
        return false
    }

    private mutating func ternary() throws -> KaitaiExpr {
        let c = try or()
        guard take("?") else { return c }
        let a = try ternary()
        guard take(":") else { throw KaitaiError.parse("expected :") }
        return .ternary(c, a, try ternary())
    }

    private mutating func or() throws -> KaitaiExpr {
        var l = try and()
        while takeName("or") { l = .binary("or", l, try and()) }
        return l
    }

    private mutating func and() throws -> KaitaiExpr {
        var l = try not()
        while takeName("and") { l = .binary("and", l, try not()) }
        return l
    }

    private mutating func not() throws -> KaitaiExpr {
        if takeName("not") { return .unary("not", try not()) }
        return try comparison()
    }

    private mutating func binary(_ ops: [String], _ next: (inout KaitaiExprParser) throws -> KaitaiExpr) throws -> KaitaiExpr {
        var l = try next(&self)
        while true {
            guard let op = ops.first(where: { take($0) }) else { return l }
            l = .binary(op, l, try next(&self))
        }
    }

    private mutating func comparison() throws -> KaitaiExpr { try binary(["==", "!=", "<=", ">=", "<", ">"]) { try $0.bitOr() } }
    private mutating func bitOr() throws -> KaitaiExpr { try binary(["|", "^"]) { try $0.bitAnd() } }
    private mutating func bitAnd() throws -> KaitaiExpr { try binary(["&"]) { try $0.shift() } }
    private mutating func shift() throws -> KaitaiExpr { try binary(["<<", ">>"]) { try $0.add() } }
    private mutating func add() throws -> KaitaiExpr { try binary(["+", "-"]) { try $0.multiply() } }
    private mutating func multiply() throws -> KaitaiExpr { try binary(["*", "/", "%"]) { try $0.unary() } }

    private mutating func unary() throws -> KaitaiExpr {
        if take("-") { return .unary("-", try unary()) }
        if take("~") { return .unary("~", try unary()) }
        return try postfix()
    }

    private mutating func postfix() throws -> KaitaiExpr {
        var e = try primary()
        while true {
            if take(".") {
                guard case .name(let n)? = peek else { throw KaitaiError.parse("expected a name") }
                at += 1
                if n == "as", take("<") {
                    // A cast changes nothing here, as values carry their own kind.
                    var depth = 1
                    while depth > 0, let t = peek {
                        if t == .symbol("<") { depth += 1 }
                        if t == .symbol(">") { depth -= 1 }
                        at += 1
                    }
                    continue
                }
                if take("(") {
                    var args: [KaitaiExpr] = []
                    if !take(")") {
                        repeat { args.append(try ternary()) } while take(",")
                        guard take(")") else { throw KaitaiError.parse("expected )") }
                    }
                    e = .call(e, n, args)
                } else {
                    e = .member(e, n)
                }
            } else if take("[") {
                let i = try ternary()
                guard take("]") else { throw KaitaiError.parse("expected ]") }
                e = .index(e, i)
            } else {
                return e
            }
        }
    }

    private mutating func primary() throws -> KaitaiExpr {
        guard let t = peek else { throw KaitaiError.parse("unexpected end") }
        at += 1
        switch t {
        case .int(let i): return .int(i)
        case .float(let d): return .float(d)
        case .string(let s): return .string(s)
        case .name("true"): return .bool(true)
        case .name("false"): return .bool(false)
        case .name(let n):
            if take("::") {
                guard case .name(let v)? = peek else { throw KaitaiError.parse("expected an enum value") }
                at += 1
                var last = v
                while take("::") {
                    guard case .name(let more)? = peek else { throw KaitaiError.parse("expected an enum value") }
                    at += 1
                    last = more
                }
                return .enumValue(n, last)
            }
            return .name(n)
        case .symbol("("):
            let e = try ternary()
            guard take(")") else { throw KaitaiError.parse("expected )") }
            return e
        case .symbol("["):
            var items: [KaitaiExpr] = []
            if !take("]") {
                repeat { items.append(try ternary()) } while take(",")
                guard take("]") else { throw KaitaiError.parse("expected ]") }
            }
            return .array(items)
        default:
            throw KaitaiError.parse("unexpected token")
        }
    }
}

/// One telemetry definition, ready to read frames with.
final class KaitaiDecoder {
    let root: KaitaiType
    /// Which values the definition says are worth showing, in its own order.
    let fields: [(name: String, path: String)]
    private var parsed: [String: KaitaiExpr] = [:]
    private var budget = 0
    private var depth = 0

    private static let budgetPerFrame = 2_000_000
    private static let deepest = 64

    init(yaml: String) throws {
        guard let top = try Yams.load(yaml: yaml) as? [AnyHashable: Any] else { throw KaitaiError.parse("not a definition") }
        let meta = top["meta"] as? [AnyHashable: Any]
        root = KaitaiType(id: (meta?["id"] as? String) ?? "root", outer: nil)
        fields = Self.fieldList(top["doc"] as? String ?? "")
        try Self.fill(root, from: top)
    }

    /// Definitions list what to output in their documentation: ":field battery_voltage: payload.vbat".
    static func fieldList(_ doc: String) -> [(name: String, path: String)] {
        doc.split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(":field ") else { return nil }
            let body = t.dropFirst(7)
            guard let colon = body.firstIndex(of: ":") else { return nil }
            let name = body[..<colon].trimmingCharacters(in: .whitespaces)
            let path = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || path.isEmpty ? nil : (name, path)
        }
    }

    /// Numbers written as 12, 0x0C or 0b1100.
    private static func number(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        if t.hasPrefix("0b") { return Int(t.dropFirst(2), radix: 2) }
        return Int(t)
    }

    private static func text(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    private static func fill(_ type: KaitaiType, from map: [AnyHashable: Any]) throws {
        if let meta = map["meta"] as? [AnyHashable: Any] {
            if let endian = meta["endian"] as? String { type.bigEndian = endian != "le" }
            if let endian = meta["bit-endian"] as? String { type.bitsLittle = endian == "le" }
        }
        if let list = map["params"] as? [[AnyHashable: Any]] { type.params = list.compactMap { $0["id"] as? String } }
        if let list = map["enums"] as? [AnyHashable: Any] {
            for (name, values) in list {
                guard let name = name as? String, let values = values as? [AnyHashable: Any] else { continue }
                var table: [String: Int] = [:]
                for (key, entry) in values {
                    let id = (entry as? [AnyHashable: Any]).flatMap { $0["id"] as? String } ?? (entry as? String) ?? String(describing: entry)
                    if let k = key as? Int ?? (key as? String).flatMap(number) { table[id] = k }
                }
                type.enums[name] = table
            }
        }
        if let nested = map["types"] as? [AnyHashable: Any] {
            for (name, body) in nested {
                guard let name = name as? String, let body = body as? [AnyHashable: Any] else { continue }
                let t = KaitaiType(id: name, outer: type)
                type.types[name] = t
                try fill(t, from: body)
            }
        }
        if let seq = map["seq"] as? [Any] {
            type.seq = seq.compactMap { ($0 as? [AnyHashable: Any]).map(attribute) }
        }
        if let inst = map["instances"] as? [AnyHashable: Any] {
            for (name, body) in inst {
                guard let name = name as? String, let body = body as? [AnyHashable: Any] else { continue }
                let a = attribute(body)
                a.id = name
                type.instances[name] = a
            }
        }
    }

    private static func attribute(_ m: [AnyHashable: Any]) -> KaitaiAttr {
        let a = KaitaiAttr()
        a.id = text(m["id"]) ?? ""
        a.type = m["type"]
        a.size = text(m["size"])
        a.sizeEos = (m["size-eos"] as? Bool) ?? false
        a.terminator = m["terminator"] as? Int ?? (m["terminator"] as? String).flatMap(number)
        a.includeTerminator = (m["include"] as? Bool) ?? false
        a.consume = (m["consume"] as? Bool) ?? true
        if let c = m["contents"] as? [Any] {
            a.contents = c.flatMap { item -> [UInt8] in
                if let i = item as? Int { return [UInt8(truncatingIfNeeded: i)] }
                if let s = item as? String { return Array(s.utf8) }
                return []
            }
        } else if let s = m["contents"] as? String {
            a.contents = Array(s.utf8)
        }
        a.condition = text(m["if"])
        a.repeatKind = m["repeat"] as? String
        a.repeatExpr = text(m["repeat-expr"])
        a.repeatUntil = text(m["repeat-until"])
        a.process = m["process"] as? String
        a.value = text(m["value"])
        a.pos = text(m["pos"])
        a.valid = m["valid"]
        a.enumName = m["enum"] as? String
        return a
    }

    // MARK: Reading a frame

    /// Every listed value this frame has. Nil if the frame doesn't fit this definition at all.
    func decode(_ frame: [UInt8]) -> [(name: String, value: String)]? {
        budget = Self.budgetPerFrame
        depth = 0
        let top = KaitaiObject(type: root, parent: nil, root: nil, io: KaitaiStream(frame))
        do {
            try read(top)
        } catch {
            return nil
        }
        var out: [(name: String, value: String)] = []
        for field in fields {
            guard let value = try? walk(field.path, from: top), let shown = value.display, !shown.isEmpty else { continue }
            out.append((field.name, shown))
        }
        return out
    }

    /// Listed paths are "a.b.0.c" or "a.b[0].c".
    private func walk(_ path: String, from top: KaitaiObject) throws -> KaitaiValue {
        var current = KaitaiValue.object(top)
        let steps = path.replacingOccurrences(of: "[", with: ".").replacingOccurrences(of: "]", with: "").split(separator: ".")
        for step in steps {
            switch current {
            case .object(let o):
                current = try member(String(step), of: o)
            case .array(let a):
                guard let i = Int(step), i >= 0, i < a.count else { throw KaitaiError.endOfData }
                current = a[i]
            case .bytes(let b):
                guard let i = Int(step), i >= 0, i < b.count else { throw KaitaiError.endOfData }
                current = .int(Int(b[i]))
            default:
                current = try call(current, String(step), [], top)
            }
        }
        return current
    }

    private func spend() throws {
        budget -= 1
        if budget < 0 { throw KaitaiError.tooDeep }
    }

    private func read(_ object: KaitaiObject) throws {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.deepest else { throw KaitaiError.tooDeep }
        for attribute in object.type.seq {
            try spend()
            if let c = attribute.condition, !(try truth(evaluate(c, in: object))) { continue }
            object.values[attribute.id] = try readAttribute(attribute, in: object, stream: object.io)
        }
    }

    private func readAttribute(_ a: KaitaiAttr, in object: KaitaiObject, stream: KaitaiStream) throws -> KaitaiValue {
        guard let kind = a.repeatKind else {
            let v = try readOne(a, in: object, stream: stream)
            try check(a, v, in: object)
            return v
        }
        var items: [KaitaiValue] = []
        switch kind {
        case "eos":
            while !stream.eof {
                try spend()
                items.append(try readOne(a, in: object, stream: stream))
            }
        case "expr":
            guard let e = a.repeatExpr, case .int(let n) = try evaluate(e, in: object), n >= 0, n <= 1_000_000 else { throw KaitaiError.invalid("repeat") }
            for i in 0..<n {
                try spend()
                object.values["_index"] = .int(i)
                items.append(try readOne(a, in: object, stream: stream))
            }
        case "until":
            guard let e = a.repeatUntil else { throw KaitaiError.invalid("repeat") }
            while true {
                try spend()
                let v = try readOne(a, in: object, stream: stream)
                items.append(v)
                object.values["_"] = v
                if try truth(evaluate(e, in: object)) { break }
            }
        default:
            throw KaitaiError.unsupported(kind)
        }
        return .array(items)
    }

    /// Some definitions insist a field holds a particular value, which is how a wrong frame is caught.
    private func check(_ a: KaitaiAttr, _ v: KaitaiValue, in object: KaitaiObject) throws {
        guard let valid = a.valid else { return }
        func matches(_ expected: Any) throws -> Bool {
            if let s = expected as? String { return try equal(v, evaluate(s, in: object)) }
            if let i = expected as? Int { return try equal(v, .int(i)) }
            return true
        }
        if let m = valid as? [AnyHashable: Any] {
            if let eq = m["eq"], !(try matches(eq)) { throw KaitaiError.invalid(a.id) }
            if let any = m["any-of"] as? [Any], !(try any.contains(where: matches)) { throw KaitaiError.invalid(a.id) }
            if let minimum = m["min"], case .int(let low) = try evaluate(String(describing: minimum), in: object), case .int(let got) = v, got < low { throw KaitaiError.invalid(a.id) }
            if let maximum = m["max"], case .int(let high) = try evaluate(String(describing: maximum), in: object), case .int(let got) = v, got > high { throw KaitaiError.invalid(a.id) }
        } else if !(try matches(valid)) {
            throw KaitaiError.invalid(a.id)
        }
    }

    private func readOne(_ a: KaitaiAttr, in object: KaitaiObject, stream: KaitaiStream) throws -> KaitaiValue {
        if let contents = a.contents {
            guard try stream.read(contents.count) == contents else { throw KaitaiError.invalid(a.id) }
            return .bytes(contents)
        }
        var typeName: String?
        if let s = a.type as? String {
            typeName = s
        } else if let sw = a.type as? [AnyHashable: Any], let on = sw["switch-on"] {
            let subject = try evaluate(String(describing: on), in: object)
            let cases = sw["cases"] as? [AnyHashable: Any] ?? [:]
            var chosen: String?
            for (key, target) in cases {
                let keyText = String(describing: key.base)
                if keyText == "_" { continue }
                if try equal(subject, evaluate(keyText, in: object)) { chosen = target as? String; break }
            }
            typeName = chosen ?? cases["_"] as? String
        }
        // A size means reading from just those bytes, with any leftovers discarded.
        var source = stream
        var raw: [UInt8]?
        if let e = a.size {
            guard case .int(let n) = try evaluate(e, in: object) else { throw KaitaiError.invalid("size") }
            raw = try stream.read(n)
        } else if a.sizeEos {
            raw = try stream.read(stream.bytes.count - stream.pos)
        }
        if let t = a.terminator, typeName == nil || typeName == "str" {
            if let sized = raw {
                // With a size as well, the terminator only ends the text early.
                let end = sized.firstIndex(of: UInt8(truncatingIfNeeded: t)) ?? sized.count
                raw = Array(sized[..<(a.includeTerminator ? min(end + 1, sized.count) : end)])
            } else {
                raw = try readTerminated(stream, terminator: t, a)
            }
        }
        if var bytes = raw {
            if let p = a.process { bytes = try process(p, bytes) }
            raw = bytes
            source = KaitaiStream(bytes)
        }
        guard let typeName else {
            if let raw { return .bytes(raw) }
            throw KaitaiError.unsupported("no type or size on \(a.id)")
        }
        let big = object.type.isBigEndian
        switch typeName {
        case "str":
            return .string(String(decoding: raw ?? [], as: UTF8.self))
        case "strz":
            if let raw {
                let end = raw.firstIndex(of: 0) ?? raw.count
                return .string(String(decoding: raw[..<end], as: UTF8.self))
            }
            return .string(String(decoding: try readTerminated(stream, terminator: 0, a), as: UTF8.self))
        default:
            break
        }
        if let v = try readBuiltIn(typeName, source, defaultBig: big, bitsLittle: object.type.isBitsLittle) {
            if let enumName = a.enumName, let table = object.type.findEnum(enumName) {
                var number: Int?
                if case .int(let i) = v { number = i }
                if case .bool(let b) = v { number = b ? 1 : 0 }
                if let number {
                    if let word = table.first(where: { $0.value == number })?.key { return .named(number, word) }
                    return .int(number)
                }
            }
            return v
        }
        // A user type, maybe with arguments: "packet(_root.length)".
        var name = typeName
        var args: [KaitaiValue] = []
        if let open = typeName.firstIndex(of: "("), typeName.hasSuffix(")") {
            name = String(typeName[..<open])
            let inner = typeName[typeName.index(after: open)..<typeName.index(before: typeName.endIndex)]
            if case .array(let list) = try evaluate("[" + inner + "]", in: object) { args = list }
        }
        guard let type = object.type.find(name) else { throw KaitaiError.unsupported("type \(name)") }
        let child = KaitaiObject(type: type, parent: object, root: object.root, io: source)
        for (i, param) in type.params.enumerated() where i < args.count { child.values[param] = args[i] }
        try read(child)
        return .object(child)
    }

    private func readBuiltIn(_ name: String, _ s: KaitaiStream, defaultBig: Bool, bitsLittle: Bool) throws -> KaitaiValue? {
        if name.first == "b" {
            var digits = name.dropFirst()
            var little = bitsLittle
            if digits.hasSuffix("le") { little = true; digits = digits.dropLast(2) } else if digits.hasSuffix("be") { little = false; digits = digits.dropLast(2) }
            if let n = Int(digits), n > 0, n <= 64 {
                let v = little ? try s.readBitsLittle(n) : try s.readBits(n)
                return n == 1 ? .bool(v == 1) : .int(Int(truncatingIfNeeded: v))
            }
        }
        var core = name
        var big = defaultBig
        if core.hasSuffix("le") { big = false; core.removeLast(2) } else if core.hasSuffix("be") { big = true; core.removeLast(2) }
        guard let kind = core.first, let width = Int(core.dropFirst()) else { return nil }
        switch (kind, width) {
        case ("u", 1), ("u", 2), ("u", 4), ("u", 8):
            return .int(Int(truncatingIfNeeded: try s.readInt(width, bigEndian: big)))
        case ("s", 1): return .int(Int(Int8(truncatingIfNeeded: try s.readInt(1, bigEndian: big))))
        case ("s", 2): return .int(Int(Int16(truncatingIfNeeded: try s.readInt(2, bigEndian: big))))
        case ("s", 4): return .int(Int(Int32(truncatingIfNeeded: try s.readInt(4, bigEndian: big))))
        case ("s", 8): return .int(Int(truncatingIfNeeded: try s.readInt(8, bigEndian: big)))
        case ("f", 4): return .float(Double(Float(bitPattern: UInt32(truncatingIfNeeded: try s.readInt(4, bigEndian: big)))))
        case ("f", 8): return .float(Double(bitPattern: try s.readInt(8, bigEndian: big)))
        default: return nil
        }
    }

    private func readTerminated(_ s: KaitaiStream, terminator: Int, _ a: KaitaiAttr) throws -> [UInt8] {
        s.align()
        var out: [UInt8] = []
        while true {
            guard s.pos < s.bytes.count else {
                if a.terminator == nil || a.type as? String == "strz" || !out.isEmpty { return out }
                throw KaitaiError.endOfData
            }
            let b = s.bytes[s.pos]
            if Int(b) == terminator {
                if a.includeTerminator { out.append(b) }
                if a.consume { s.pos += 1 }
                return out
            }
            out.append(b)
            s.pos += 1
        }
    }

    private func process(_ spec: String, _ bytes: [UInt8]) throws -> [UInt8] {
        let plain = spec.replacingOccurrences(of: "satnogsdecoders.process.", with: "")
        var name = plain
        var args: [Int] = []
        if let open = plain.firstIndex(of: "("), plain.hasSuffix(")") {
            name = String(plain[..<open])
            args = plain[plain.index(after: open)...].dropLast().split(separator: ",").compactMap {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("0x") ? Int(t.dropFirst(2), radix: 16) : Int(t)
            }
        }
        switch (name, args.count) {
        case ("ror", 1):
            let k = UInt8(args[0] & 7)
            return k == 0 ? bytes : bytes.map { ($0 >> k) | ($0 << (8 - k)) }
        case ("rol", 1):
            let k = UInt8(args[0] & 7)
            return k == 0 ? bytes : bytes.map { ($0 << k) | ($0 >> (8 - k)) }
        case ("xor", 1):
            return bytes.map { $0 ^ UInt8(truncatingIfNeeded: args[0]) }
        case ("hexl", 0):
            return Array(bytes.map { String(format: "%02x", $0) }.joined().utf8)
        case ("unhexl", 0):
            guard bytes.count % 2 == 0 else { throw KaitaiError.invalid("hex") }
            let text = String(decoding: bytes, as: UTF8.self)
            return try stride(from: 0, to: bytes.count, by: 2).map { i -> UInt8 in
                let start = text.utf8.index(text.startIndex, offsetBy: i)
                let end = text.utf8.index(start, offsetBy: 2)
                guard let b = UInt8(text[start..<end], radix: 16) else { throw KaitaiError.invalid("hex") }
                return b
            }
        case ("b64encode", 0):
            return Array(Data(bytes).base64EncodedData())
        case ("b64decode", 0):
            guard let d = Data(base64Encoded: Data(bytes)) else { throw KaitaiError.invalid("base64") }
            return Array(d)
        case ("b85encode", 0): return Self.ascii85Encode(bytes)
        case ("b85decode", 0): return try Self.ascii85Decode(bytes)
        case ("elfin_pp", 0):
            var out: [UInt8] = []
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x27, i + 1 < bytes.count, [0x27, 0x5E, 0x93].contains(bytes[i + 1]) { i += 1 }
                out.append(bytes[i])
                i += 1
            }
            return out
        case ("scrambler", 3):
            var reg = args[1]
            var out = bytes
            for i in out.indices {
                var mask: UInt8 = 0
                for bit in (0..<8).reversed() {
                    if reg & 1 == 1 { mask |= 1 << UInt8(bit) }
                    let feedback = (reg & args[0]).nonzeroBitCount % 2
                    reg = (reg >> 1) | (feedback << args[2])
                }
                out[i] ^= mask
            }
            return out
        default:
            throw KaitaiError.unsupported(spec)
        }
    }

    /// Named b85 in these definitions, but what they actually use is Ascii85.
    static func ascii85Encode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let chunk = Array(bytes[i..<min(i + 4, bytes.count)])
            let word = (chunk + [UInt8](repeating: 0, count: 4 - chunk.count)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            var digits = [UInt8](repeating: 0, count: 5)
            var v = word
            for k in (0..<5).reversed() {
                digits[k] = UInt8(v % 85) + 33
                v /= 85
            }
            out += digits.prefix(chunk.count + 1)
            i += 4
        }
        return out
    }

    static func ascii85Decode(_ bytes: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var group: [UInt8] = []
        func flush(_ g: [UInt8]) throws {
            let padded = g + [UInt8](repeating: 117, count: 5 - g.count)
            var word: UInt64 = 0
            for c in padded { word = word * 85 + UInt64(c - 33) }
            guard word <= UInt64(UInt32.max) else { throw KaitaiError.invalid("ascii85") }
            let four = (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt64(24 - 8 * $0)) }
            out += four.prefix(g.count - 1)
        }
        for c in bytes {
            if c == 0x20 || (0x09...0x0D).contains(c) { continue }
            if c == 0x7A, group.isEmpty { out += [0, 0, 0, 0]; continue }
            guard (33...117).contains(c) else { throw KaitaiError.invalid("ascii85") }
            group.append(c)
            if group.count == 5 {
                try flush(group)
                group = []
            }
        }
        if group.count == 1 { throw KaitaiError.invalid("ascii85") }
        if !group.isEmpty { try flush(group) }
        return out
    }

    // MARK: Expressions

    private func evaluate(_ text: String, in object: KaitaiObject) throws -> KaitaiValue {
        let expr: KaitaiExpr
        if let hit = parsed[text] {
            expr = hit
        } else {
            expr = try KaitaiExprParser.parse(text)
            parsed[text] = expr
        }
        return try run(expr, object)
    }

    private func truth(_ v: KaitaiValue) throws -> Bool {
        switch v.plain {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: throw KaitaiError.invalid("not a condition")
        }
    }

    private func equal(_ a: KaitaiValue, _ b: KaitaiValue) throws -> Bool {
        switch (a.plain, b.plain) {
        case (.int(let x), .int(let y)): return x == y
        case (.float(let x), .float(let y)): return x == y
        case (.int(let x), .float(let y)), (.float(let y), .int(let x)): return Double(x) == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.bool(let x), .int(let y)), (.int(let y), .bool(let x)): return (x ? 1 : 0) == y
        case (.string(let x), .string(let y)): return x == y
        case (.bytes(let x), .bytes(let y)): return x == y
        case (.bytes(let x), .array(let y)), (.array(let y), .bytes(let x)):
            guard x.count == y.count else { return false }
            for (p, q) in zip(x, y) where !(try equal(.int(Int(p)), q)) { return false }
            return true
        default: return false
        }
    }

    private func member(_ name: String, of object: KaitaiObject) throws -> KaitaiValue {
        if let v = object.values[name] { return v }
        if let a = object.type.instances[name] {
            guard object.computing.insert(name).inserted else { throw KaitaiError.invalid("loop in \(name)") }
            defer { object.computing.remove(name) }
            try spend()
            if let c = a.condition, !(try truth(evaluate(c, in: object))) { throw KaitaiError.invalid("not present") }
            let v: KaitaiValue
            if let e = a.value {
                v = try evaluate(e, in: object)
            } else {
                let saved = object.io.pos
                object.io.align()
                if let p = a.pos, case .int(let at) = try evaluate(p, in: object) { object.io.pos = at }
                defer { object.io.pos = saved; object.io.align() }
                v = try readAttribute(a, in: object, stream: object.io)
            }
            object.values[name] = v
            return v
        }
        throw KaitaiError.invalid("no \(name) in \(object.type.id)")
    }

    private func run(_ e: KaitaiExpr, _ object: KaitaiObject) throws -> KaitaiValue {
        try spend()
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.deepest * 8 else { throw KaitaiError.tooDeep }
        switch e {
        case .int(let i): return .int(i)
        case .float(let d): return .float(d)
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .array(let items): return .array(try items.map { try run($0, object) })
        case .enumValue(let en, let v):
            guard let table = object.type.findEnum(en), let i = table[v] else { throw KaitaiError.invalid("enum \(en)") }
            return .int(i)
        case .name(let n):
            switch n {
            case "_root": return .object(object.root)
            case "_parent":
                guard let p = object.parent else { throw KaitaiError.invalid("no parent") }
                return .object(p)
            case "_io": return .object(ioObject(object))
            default: return try member(n, of: object)
            }
        case .member(let base, let name):
            if case .name("_io") = base { return try ioMember(name, object.io) }
            if case .member(_, "_io") = base, case .object(let o) = try run(memberOwner(base), object) { return try ioMember(name, o.io) }
            let v = try run(base, object)
            if case .object(let o) = v {
                switch name {
                case "_parent":
                    guard let p = o.parent else { throw KaitaiError.invalid("no parent") }
                    return .object(p)
                case "_root": return .object(o.root)
                default: return try member(name, of: o)
                }
            }
            return try call(v, name, [], object)
        case .call(let base, let name, let args):
            return try call(run(base, object), name, args.map { try run($0, object) }, object)
        case .index(let base, let i):
            guard case .int(let n) = try run(i, object).plain else { throw KaitaiError.invalid("index") }
            switch try run(base, object) {
            case .array(let a):
                guard n >= 0, n < a.count else { throw KaitaiError.endOfData }
                return a[n]
            case .bytes(let b):
                guard n >= 0, n < b.count else { throw KaitaiError.endOfData }
                return .int(Int(b[n]))
            default:
                throw KaitaiError.invalid("index")
            }
        case .unary(let op, let x):
            let v = try run(x, object).plain
            switch (op, v) {
            case ("-", .int(let i)): return .int(0 &- i)
            case ("-", .float(let d)): return .float(-d)
            case ("~", .int(let i)): return .int(~i)
            case ("not", _): return .bool(!(try truth(v)))
            default: throw KaitaiError.invalid("unary")
            }
        case .ternary(let c, let a, let b):
            return try run(truth(run(c, object)) ? a : b, object)
        case .binary(let op, let l, let r):
            if op == "and" { return .bool(try truth(run(l, object)) && truth(run(r, object))) }
            if op == "or" { return .bool(try truth(run(l, object)) || truth(run(r, object))) }
            return try arithmetic(op, run(l, object), run(r, object))
        }
    }

    private func memberOwner(_ e: KaitaiExpr) -> KaitaiExpr {
        if case .member(let owner, _) = e { return owner }
        return e
    }

    private func ioObject(_ object: KaitaiObject) -> KaitaiObject { object }

    private func ioMember(_ name: String, _ s: KaitaiStream) throws -> KaitaiValue {
        switch name {
        case "pos": return .int(s.pos)
        case "size": return .int(s.bytes.count)
        case "eof", "is_eof": return .bool(s.eof)
        default: throw KaitaiError.unsupported("_io.\(name)")
        }
    }

    private func arithmetic(_ op: String, _ first: KaitaiValue, _ second: KaitaiValue) throws -> KaitaiValue {
        let a = first.plain, b = second.plain
        if op == "==" { return .bool(try equal(a, b)) }
        if op == "!=" { return .bool(!(try equal(a, b))) }
        if case .string(let x) = a, case .string(let y) = b {
            switch op {
            case "+": return .string(x + y)
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: throw KaitaiError.invalid(op)
            }
        }
        func number(_ v: KaitaiValue) -> KaitaiValue {
            if case .bool(let f) = v { return .int(f ? 1 : 0) }
            return v
        }
        switch (number(a), number(b)) {
        case (.int(let x), .int(let y)):
            switch op {
            case "+": return .int(x &+ y)
            case "-": return .int(x &- y)
            case "*": return .int(x &* y)
            case "/":
                guard y != 0 else { throw KaitaiError.invalid("divide by zero") }
                // Rounds down, not towards zero.
                let q = x / y
                return .int((x % y != 0 && (x < 0) != (y < 0)) ? q - 1 : q)
            case "%":
                guard y != 0 else { throw KaitaiError.invalid("divide by zero") }
                let m = x % y
                return .int(m != 0 && (m < 0) != (y < 0) ? m + y : m)
            case "&": return .int(x & y)
            case "|": return .int(x | y)
            case "^": return .int(x ^ y)
            case "<<": return .int(y >= 64 ? 0 : x << y)
            case ">>": return .int(y >= 64 ? 0 : x >> y)
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: throw KaitaiError.invalid(op)
            }
        case (.int, .float), (.float, .int), (.float, .float):
            func d(_ v: KaitaiValue) -> Double {
                switch v {
                case .int(let i): return Double(i)
                case .float(let f): return f
                default: return 0
                }
            }
            let x = d(number(a)), y = d(number(b))
            switch op {
            case "+": return .float(x + y)
            case "-": return .float(x - y)
            case "*": return .float(x * y)
            case "/": return .float(x / y)
            case "%":
                let m = fmod(x, y)
                return .float(m != 0 && (m < 0) != (y < 0) ? m + y : m)
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            default: throw KaitaiError.invalid(op)
            }
        default:
            throw KaitaiError.invalid(op)
        }
    }

    private func call(_ value: KaitaiValue, _ name: String, _ args: [KaitaiValue], _ object: KaitaiObject) throws -> KaitaiValue {
        let v = value.plain
        switch (name, v) {
        case ("to_s", .int(let i)):
            if case .int(let radix)? = args.first { return .string(String(i, radix: radix)) }
            return .string(String(i))
        case ("to_s", .float(let d)): return .string(String(d))
        case ("to_s", .bool(let b)): return .string(b ? "true" : "false")
        case ("to_s", .string): return v
        case ("to_s", .bytes(let b)): return .string(String(decoding: b, as: UTF8.self))
        case ("to_i", .int): return v
        case ("to_i", .float(let d)):
            guard d.isFinite, abs(d) < 9e18 else { throw KaitaiError.invalid("to_i") }
            return .int(Int(d))
        case ("to_i", .bool(let b)): return .int(b ? 1 : 0)
        case ("to_i", .string(let s)):
            var radix = 10
            if case .int(let r)? = args.first { radix = r }
            guard let i = Int(s.trimmingCharacters(in: .whitespaces), radix: radix) else { throw KaitaiError.invalid("to_i of \(s)") }
            return .int(i)
        case ("to_f", .int(let i)): return .float(Double(i))
        case ("to_f", .float): return v
        case ("length", .string(let s)): return .int(s.count)
        case ("size", .bytes(let b)), ("length", .bytes(let b)): return .int(b.count)
        case ("size", .array(let a)), ("length", .array(let a)): return .int(a.count)
        case ("reverse", .string(let s)): return .string(String(s.reversed()))
        case ("substring", .string(let s)):
            guard args.count == 2, case .int(let a) = args[0], case .int(let b) = args[1], a >= 0, b >= a else { throw KaitaiError.invalid("substring") }
            let c = Array(s)
            guard a <= c.count else { return .string("") }
            return .string(String(c[a..<min(b, c.count)]))
        case ("first", .array(let a)):
            guard let f = a.first else { throw KaitaiError.endOfData }
            return f
        case ("last", .array(let a)):
            guard let l = a.last else { throw KaitaiError.endOfData }
            return l
        case ("first", .bytes(let b)):
            guard let f = b.first else { throw KaitaiError.endOfData }
            return .int(Int(f))
        case ("last", .bytes(let b)):
            guard let l = b.last else { throw KaitaiError.endOfData }
            return .int(Int(l))
        default:
            throw KaitaiError.unsupported("\(name)")
        }
    }
}
