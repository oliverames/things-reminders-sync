import Foundation

/// Things ids are 16-byte UUIDs in Bitcoin-style base58 (leading zero bytes become leading "1"s).
/// Things decodes every id into a 16-byte buffer and traps when an id needs more bytes. Twenty-two
/// random base58 characters overflow about 45% of the time, which broke sync on 2026-11-09.
enum ThingsID {
    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    static let byteCount = 16

    private static let digitOf: [UInt8: Int] = {
        var map: [UInt8: Int] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = i }
        return map
    }()

    /// Arbitrary-precision base256 -> base58 by repeated multiply-and-carry over a digit array.
    static func encodeBase58(_ bytes: [UInt8]) -> String {
        var zeros = 0
        while zeros < bytes.count, bytes[zeros] == 0 { zeros += 1 }
        var digits: [UInt8] = [] // base58 digits, least significant first
        for byte in bytes {
            var carry = Int(byte)
            for i in digits.indices {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        var out = [UInt8](repeating: alphabet[0], count: zeros)
        out.append(contentsOf: digits.reversed().map { alphabet[Int($0)] })
        return String(decoding: out, as: UTF8.self)
    }

    /// Number of bytes an id decodes to, or -1 when it is not base58 at all.
    static func base58ByteLength(_ id: String) -> Int {
        let chars = Array(id.utf8)
        if chars.isEmpty { return -1 }
        var zeros = 0
        while zeros < chars.count, chars[zeros] == alphabet[0] { zeros += 1 }
        var bytes: [UInt8] = [] // base256, least significant first
        for ch in chars {
            guard let digit = digitOf[ch] else { return -1 }
            var carry = digit
            for i in bytes.indices {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        return zeros + bytes.count
    }

    static func isValid(_ id: String) -> Bool { base58ByteLength(id) == byteCount }

    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return encodeBase58(bytes)
    }
}

enum ThingsCRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ text: String) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in text.utf8 { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// One entry of a change map: `t` 0 create, 1 update, 2 delete; `e` the versioned entity; `p` properties.
struct ThingsChange: Sendable, Equatable {
    var t: Int
    var e: String
    var p: [String: JSONValue]

    var json: JSONValue { .object(["t": .number(Double(t)), "e": .string(e), "p": .object(p)]) }
}

typealias ThingsChangeMap = [String: ThingsChange]

enum ThingsChangeValidator {
    static let idListKeys = ["pr", "agr", "ar", "tg", "ts", "rt", "dl", "pn"]
    static let timestampKeys = ["cd", "md", "sp", "lai"]
    static let calendarDateKeys = ["sr", "tir", "dd"]
    /// 2100-01-01; anything later is milliseconds or garbage.
    static let latestTimestamp = 4_102_444_800.0

    /// Throws `ThingsCloudError.invalidChange` before anything reaches Things Cloud if a change carries
    /// an id or date that the Things apps cannot decode. Every write funnels through the client's commit.
    static func validate(_ map: ThingsChangeMap) throws {
        var problems: [String] = []
        for (id, change) in map.sorted(by: { $0.key < $1.key }) {
            if !ThingsID.isValid(id) { problems.append("entity id \"\(id)\" is not a Things id") }
            if ![0, 1, 2].contains(change.t) { problems.append("\(id): change type \(change.t) is not 0, 1, or 2") }
            if change.e.range(of: #"^[A-Za-z]+\d+$"#, options: .regularExpression) == nil {
                problems.append("\(id): entity \"\(change.e)\" is not a versioned entity name")
            }
            for key in idListKeys {
                guard let value = change.p[key] else { continue }
                guard let refs = value.array else {
                    problems.append("\(id): \(key) must be an array of ids")
                    continue
                }
                for ref in refs {
                    guard let s = ref.string, ThingsID.isValid(s) else {
                        problems.append("\(id): \(key) reference \(ref.serialized()) is not a Things id")
                        continue
                    }
                }
            }
            for key in timestampKeys + calendarDateKeys {
                guard let value = change.p[key], !value.isNull else { continue }
                guard let v = value.double, v.isFinite, v >= 0, v <= latestTimestamp else {
                    problems.append("\(id): \(key) must be unix seconds, got \(value.serialized())")
                    continue
                }
                if calendarDateKeys.contains(key), v.truncatingRemainder(dividingBy: 86400) != 0 {
                    problems.append("\(id): \(key) must be midnight UTC, got \(Int64(v))")
                }
            }
        }
        if !problems.isEmpty { throw ThingsCloudError.invalidChange(problems) }
    }
}
