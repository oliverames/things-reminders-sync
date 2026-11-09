import Foundation

/// Minimal JSON value that keeps numbers as numbers and `null` as null on the wire.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Parsing

    static func parse(_ data: Data) throws -> JSONValue {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ThingsCloudError.decoding(error.localizedDescription)
        }
        return convert(any)
    }

    private static func convert(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(convert))
        case let o as [String: Any]: return .object(o.mapValues(convert))
        default: return .null
        }
    }

    // MARK: Accessors

    var string: String? { if case let .string(s) = self { return s } else { return nil } }
    var double: Double? { if case let .number(n) = self { return n } else { return nil } }
    var int: Int? {
        guard case let .number(n) = self, n.isFinite, abs(n) < 9e15 else { return nil }
        return Int(n)
    }
    var array: [JSONValue]? { if case let .array(a) = self { return a } else { return nil } }
    var object: [String: JSONValue]? { if case let .object(o) = self { return o } else { return nil } }
    var isNull: Bool { if case .null = self { return true } else { return false } }
    /// JS-style truthiness for flags such as `tr` that Things writes as a bool or 0/1.
    var flag: Bool {
        switch self {
        case let .bool(b): return b
        case let .number(n): return n != 0
        default: return false
        }
    }
    subscript(key: String) -> JSONValue? { object?[key] }

    // MARK: Serialization (sorted keys, so output is deterministic)

    func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    func data() -> Data { Data(serialized().utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n): out += Self.format(n)
        case let .string(s): Self.writeString(s, to: &out)
        case let .array(a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case let .object(o):
            out += "{"
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                o[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func format(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return "\(n)"
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
