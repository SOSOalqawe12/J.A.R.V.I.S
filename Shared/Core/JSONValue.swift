import Foundation

/// A small, dependency-free JSON value used for API request/response bodies,
/// tool arguments and JSON schemas. Keeps provider adapters flexible without
/// having to mirror every API type as a Codable struct.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? { doubleValue.map { Int($0) } }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased())
        case .number(let n): return n != 0
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: Serialization helpers

    func encodedData(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    func jsonString(pretty: Bool = false) -> String {
        String(decoding: encodedData(pretty: pretty), as: UTF8.self)
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    /// Extracts the first JSON object found in free-form model text
    /// (handles ```json fences and leading/trailing prose).
    static func extractObject(from text: String) -> JSONValue? {
        var candidate = text
        if let fenceStart = candidate.range(of: "```") {
            let afterFence = candidate[fenceStart.upperBound...]
            let body = afterFence.drop(while: { $0 != "\n" })
            if let fenceEnd = body.range(of: "```") {
                candidate = String(body[..<fenceEnd.lowerBound])
            }
        }
        guard let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end else {
            return nil
        }
        return try? parse(String(candidate[start...end]))
    }
}

// MARK: - Literal conformances

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        for (key, value) in elements { dict[key] = value }
        self = .object(dict)
    }
}

// MARK: - JSON Schema builders for tool parameters

enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var dict: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties)
        ]
        if !required.isEmpty { dict["required"] = .array(required.map { .string($0) }) }
        return .object(dict)
    }

    static func string(_ description: String, options: [String]? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let options { dict["enum"] = .array(options.map { .string($0) }) }
        return .object(dict)
    }

    static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static func array(_ description: String, items: JSONValue) -> JSONValue {
        ["type": "array", "description": .string(description), "items": items]
    }
}
