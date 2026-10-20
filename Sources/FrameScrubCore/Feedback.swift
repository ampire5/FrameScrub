import Foundation

/// A transport event the UI shows as a frameless icon over the video: seeks on their side, the rest in the centre.
public enum Feedback: Equatable, Sendable {
    case play, pause, revert, endOfFile, playlistPrevious, playlistNext
    case sceneNext, scenePrevious
    case seek(Double)
    case speed(Double)
    case volume(Int)
    case mute(Bool)

    public enum Placement: Sendable { case leading, center, trailing }

    public var placement: Placement {
        guard case let .seek(seconds) = self else { return .center }
        return seconds < 0 ? .leading : .trailing
    }

    /// SF Symbol name of the icon.
    public var symbolName: String {
        switch self {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .revert: return "arrow.uturn.backward"
        case .endOfFile: return "stop.fill"
        case .playlistPrevious: return "backward.end.fill"
        case .playlistNext: return "forward.end.fill"
        case .sceneNext: return "chevron.forward.2"
        case .scenePrevious: return "chevron.backward.2"
        case let .seek(seconds): return seconds < 0 ? "backward.fill" : "forward.fill"
        case let .speed(value): return value < 0 ? "backward.fill" : "speedometer"
        case let .volume(level):
            switch level {
            case ..<1: return "speaker.fill"
            case ..<34: return "speaker.wave.1.fill"
            case ..<67: return "speaker.wave.2.fill"
            default: return "speaker.wave.3.fill"
            }
        case let .mute(on): return on ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }
    }

    /// Short text under the icon, or nil when the icon says it all.
    public var caption: String? {
        switch self {
        case let .speed(value): return (value < 0 ? "\u{25C0} \u{2212}" : "") + Self.number(abs(value)) + "\u{00D7}"
        case let .volume(level): return "\(level) %"
        default: return nil
        }
    }

    /// Up to two decimals without trailing zeros: 2, 1.1, 0.91.
    private static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
