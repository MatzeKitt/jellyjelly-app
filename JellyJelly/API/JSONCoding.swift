import Foundation

/// A coding key that is not tied to a specific type, used by the key conversion strategies.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum JellyfinJSON {
    /// Jellyfin uses PascalCase keys; Swift models use camelCase.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!
            if key.intValue != nil {
                return key
            }
            return AnyCodingKey(stringValue: key.stringValue.lowercasedFirst)
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(raw)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            AnyCodingKey(stringValue: path.last!.stringValue.uppercasedFirst)
        }
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    /// Parses dates like `2024-03-14T00:00:00.0000000Z` (7 fractional digits), with or without zone.
    static func parseDate(_ raw: String) -> Date? {
        var value = raw
        var fraction: Double = 0
        if let dot = value.firstIndex(of: ".") {
            var end = value.index(after: dot)
            while end < value.endIndex, value[end].isNumber {
                end = value.index(after: end)
            }
            fraction = Double("0" + value[dot..<end]) ?? 0
            value.removeSubrange(dot..<end)
        }
        if value.count == 19 {
            value += "Z"
        } else if value.count == 10 {
            value += "T00:00:00Z"
        }
        lock.lock()
        defer { lock.unlock() }
        return isoFormatter.date(from: value)?.addingTimeInterval(fraction)
    }
}
