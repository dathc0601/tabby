import Foundation

/// The JSON coders every sync payload goes through: the encrypted snapshot and the HTTP API
/// bodies, on the client and on the server.
///
/// - Keys are sorted so the same value always encodes to the same bytes.
/// - `Data` is base64 (the `JSONEncoder` default).
/// - Dates are ISO 8601 in UTC with milliseconds (`2026-10-22T09:41:00.123Z`). Milliseconds
///   matter: a device that compared its own seconds-rounded upload with its local copy would
///   always see the local copy as newer and upload forever. Sub-millisecond precision is
///   rounded away (`SyncCoding.milliseconds`), and the merger compares at that precision.
///   The decoder also accepts dates without a fraction and with a `±hh:mm` offset.
public enum SyncCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected an ISO 8601 date, got \(string)")
            }
            return date
        }
        return decoder
    }

    /// Milliseconds since 1970, rounded: the precision dates have on the wire.
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `2026-10-22T09:41:00.123Z`
    public static func formatDate(_ date: Date) -> String {
        let millis = milliseconds(date)
        let (seconds, fraction) = floorDivide(millis, 1000)
        let (days, secondOfDay) = floorDivide(seconds, 86_400)
        let (year, month, day) = civil(fromDays: days)
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T"
            + "\(pad(secondOfDay / 3600, 2)):\(pad(secondOfDay % 3600 / 60, 2)):\(pad(secondOfDay % 60, 2))"
            + ".\(pad(fraction, 3))Z"
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)`; returns nil for anything else.
    public static func parseDate(_ string: String) -> Date? {
        var scanner = DateScanner(Array(string.utf8))
        guard let year = scanner.number(digits: 4), scanner.skip("-"),
              let month = scanner.number(digits: 2), scanner.skip("-"),
              let day = scanner.number(digits: 2), scanner.skip("T") || scanner.skip("t"),
              let hour = scanner.number(digits: 2), scanner.skip(":"),
              let minute = scanner.number(digits: 2), scanner.skip(":"),
              let second = scanner.number(digits: 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var millis: Int64 = 0
        if scanner.skip(".") {
            guard let fraction = scanner.fraction() else { return nil }
            millis = fraction
        }

        var offsetSeconds: Int64 = 0
        if scanner.skip("Z") || scanner.skip("z") {
            offsetSeconds = 0
        } else if let sign = scanner.sign() {
            guard let offsetHours = scanner.number(digits: 2) else { return nil }
            _ = scanner.skip(":")
            guard let offsetMinutes = scanner.number(digits: 2), offsetHours < 24, offsetMinutes < 60 else {
                return nil
            }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        } else {
            return nil
        }
        guard scanner.atEnd else { return nil }

        let days = days(fromCivil: year, month, day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds * 1000 + millis) / 1000)
    }

    // MARK: Calendar arithmetic (proleptic Gregorian, UTC; Howard Hinnant's algorithms)

    private static func floorDivide(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
        let quotient = a >= 0 ? a / b : (a - b + 1) / b
        return (quotient, a - quotient * b)
    }

    private static func civil(fromDays z: Int64) -> (Int64, Int64, Int64) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static func days(fromCivil year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

private struct DateScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { index == bytes.count }

    mutating func skip(_ character: Character) -> Bool {
        guard index < bytes.count, bytes[index] == character.asciiValue else { return false }
        index += 1
        return true
    }

    mutating func number(digits: Int) -> Int64? {
        guard index + digits <= bytes.count else { return nil }
        var value: Int64 = 0
        for byte in bytes[index..<index + digits] {
            guard (0x30...0x39).contains(byte) else { return nil }
            value = value * 10 + Int64(byte - 0x30)
        }
        index += digits
        return value
    }

    /// Fraction digits after the dot, as milliseconds (rounded).
    mutating func fraction() -> Int64? {
        let start = index
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        guard index > start else { return nil }
        let digits = bytes[start..<index].prefix(4).map { Double($0 - 0x30) }
        var value = 0.0
        for (position, digit) in digits.enumerated() { value += digit * pow(10, Double(2 - position)) }
        return Int64(value.rounded())
    }

    mutating func sign() -> Int64? {
        if skip("+") { return 1 }
        if skip("-") { return -1 }
        return nil
    }
}
