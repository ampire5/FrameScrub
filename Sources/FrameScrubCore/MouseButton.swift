import Foundation

/// A mouse button that has input names of its own: the AppKit side buttons (`MBTN_*`) and the Logitech
/// buttons the HID++ link reports (`MX_*`). Taps, holds and double taps add `_LONG` / `_DBL` to the name.
public enum MouseButton: String, CaseIterable, Sendable {
    case mid = "MBTN_MID", back = "MBTN_BACK", forward = "MBTN_FORWARD"
    case panel = "MX_PANEL", gesture = "MX_GESTURE", shift = "MX_SHIFT"

    /// The modifier that stands for the button held down; nil for buttons that cannot be held with other input.
    public var modifier: Modifiers? {
        switch self {
        case .back: .backButton
        case .forward: .forwardButton
        case .panel: .panelButton
        case .gesture: .gestureButton
        case .mid: .midButton
        case .shift: nil
        }
    }

    /// The control ID of a button that is diverted to FrameScrub while it is bound.
    public var cid: UInt16? {
        switch self {
        case .panel: 0x01A0
        case .gesture: 0x00C3
        case .shift: 0x00C4
        case .mid, .back, .forward: nil
        }
    }

    /// The control ID of a side button that is watched, or taken over (`mx-side-buttons`), over HID++.
    public var sideCID: UInt16? {
        switch self {
        case .back: 0x53
        case .forward: 0x56
        case .mid, .panel, .gesture, .shift: nil
        }
    }

    public init?(cid: UInt16) {
        guard let button = Self.allCases.first(where: { $0.cid == cid || $0.sideCID == cid }) else { return nil }
        self = button
    }

    /// `NSEvent.buttonNumber` of the other buttons: 2 middle, 3 back, 4 forward.
    public init?(appKitButtonNumber number: Int) {
        switch number {
        case 2: self = .mid
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

public enum MarkEdge: Sendable { case start, end }
