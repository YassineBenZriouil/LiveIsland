import Foundation

/// What claude-swap and ccswap print alike: ccswap is a claude-swap fork, so both write the
/// same JSON numbers and the same update notice, and one reading serves both.
enum SwitcherOutput {
    /// Account numbers, written as numbers or as strings. A number that isn't a whole one, or
    /// is too big for an `Int`, is no account's.
    static func number(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return value as? Int
    }

    /// A JSON number as a whole number, without trapping: `Int(_:)` crashes on anything past
    /// `Int`'s range, and a tool's JSON can hold any number at all.
    static func wholeNumber(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        if value >= Double(Int.max) { return .max }
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }

    /// A percentage for a line of text: rounded, and kept to 0…999 so a nonsense value still
    /// reads as a number.
    static func percent(_ value: Double) -> String {
        "\(min(max(wholeNumber(value.rounded()), 0), 999))%"
    }

    /// "A newer version of claude-swap is available (0.29.0)" → "0.29.0", for the named tool only.
    static func newerVersion(of tool: String, in output: String) -> String? {
        guard let range = output.range(of: "newer version of \(tool) is available (") else { return nil }
        let rest = output[range.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        let version = String(rest[..<end])
        return AppVersion(version) != nil ? version : nil
    }
}
