import Foundation

/// Where ⌘G jumps to (backlog 4.3): a time (`1:23`, `1:02:03.5`, `83.4`) or a frame number (`f1234`, `#1234`).
public enum GoToTarget: Equatable, Sendable {
    case seconds(Double)
    case frame(Int)

    public static func parse(_ text: String) -> GoToTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "fF#".contains(first) {
            let digits = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let n = Int(digits) else { return nil }
            return .frame(n)
        }
        let parts = trimmed.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        // Hours and minutes are whole numbers; minutes and seconds after a colon stay below 60.
        var seconds = 0.0
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            guard !part.isEmpty, part.allSatisfy({ $0.isASCIIDigit || (last && $0 == ".") }),
                  let value = Double(part) else { return nil }
            if i > 0 && value >= 60 { return nil }
            seconds = seconds * 60 + value
        }
        return .seconds(seconds)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
