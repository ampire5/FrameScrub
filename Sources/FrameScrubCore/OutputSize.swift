import CoreGraphics
import Foundation

/// How large a saved or exported frame is (`save-scale`, `export-scale`): a factor, the screen the
/// window is on, or one fixed side. The aspect ratio is always kept; larger frames are reduced.
public enum OutputSize: Equatable, Sendable, ExpressibleByIntegerLiteral {
    case scale(Int)     // 1, 2 or 4
    case fitScreen      // into the pixel size of the screen the window is on
    case width(Int)
    case height(Int)

    /// Allowed values of `width:` / `height:`; also the limit for the long side of any result.
    public static let sideRange = 16...16384

    public init(integerLiteral value: Int) { self = .scale(value) }

    public init?(text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "1", "2", "4": self = .scale(Int(value)!)
        case "fit": self = .fitScreen
        default:
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let side = Int(parts[1]), Self.sideRange.contains(side) else { return nil }
            switch parts[0] {
            case "width": self = .width(side)
            case "height": self = .height(side)
            default: return nil
            }
        }
    }

    /// The value as written in framescrub.conf.
    public var text: String {
        switch self {
        case let .scale(n): return String(n)
        case .fitScreen: return "fit"
        case let .width(n): return "width:\(n)"
        case let .height(n): return "height:\(n)"
        }
    }

    /// Pixels of the result for an upright `source`. Nil for `.fitScreen` while the screen is unknown.
    public func targetSize(source: CGSize, screen: CGSize?) -> CGSize? {
        guard source.width > 0, source.height > 0 else { return nil }
        var ratio: Double
        switch self {
        case let .scale(n): ratio = Double(n)
        case .fitScreen:
            guard let screen, screen.width > 0, screen.height > 0 else { return nil }
            ratio = min(screen.width / source.width, screen.height / source.height)
        case let .width(n): ratio = Double(n) / source.width
        case let .height(n): ratio = Double(n) / source.height
        }
        let longSide = max(source.width, source.height) * ratio
        if longSide > Double(Self.sideRange.upperBound) { ratio *= Double(Self.sideRange.upperBound) / longSide }
        return CGSize(width: max(1, (source.width * ratio).rounded()), height: max(1, (source.height * ratio).rounded()))
    }

    /// The file-name suffix before the extension: `_x2` for factors, `_WxH` for the other forms, none when
    /// the size did not change.
    public func suffix(source: CGSize, target: CGSize) -> String {
        if case let .scale(n) = self {
            // A factor the 16384 cap shrank is named by its real size.
            let exact = target.width == (source.width * Double(n)).rounded() && target.height == (source.height * Double(n)).rounded()
            if exact { return n > 1 ? "_x\(n)" : "" }
        }
        return target == source ? "" : "_\(Int(target.width))x\(Int(target.height))"
    }
}
