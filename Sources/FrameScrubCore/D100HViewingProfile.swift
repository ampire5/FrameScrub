import MouseContract

public struct D100HViewingProfile {
    public enum Action: Equatable {
        case command(Command)
        case scroll(Int, fast: Bool)
        case edge(fromEnd: Bool)
    }

    private struct Hold {
        let button: D100HButton
        let since: Double
        var usedForTurn = false

        var modifiesTurn: Bool {
            button == .topMiddle || button == .bottomLeft || button == .bottomRight
        }
    }

    private var held: [Hold] = []

    public init() {}

    public mutating func receive(_ input: D100HInput, at time: Double) -> Action? {
        switch input {
        case .cancelled:
            held.removeAll(keepingCapacity: true)
            return nil
        case let .turn(direction, knobPressed):
            let step = direction == .left ? -1 : 1
            let modifier = held.first(where: \.modifiesTurn)?.button
            for index in held.indices where held[index].modifiesTurn {
                held[index].usedForTurn = true
            }
            switch modifier {
            case .topMiddle: return .command(.stepSpeed(step))
            case .bottomLeft: return .command(.seek(Double(step) * 5, .keyframes))
            case .bottomRight: return .command(.addVolume(Double(step) * 5))
            // A positive vertical wheel delta seeks backward with the player's normal scrub settings.
            default: return .scroll(-step, fast: knobPressed)
            }
        case let .button(button, pressed):
            if pressed {
                guard !held.contains(where: { $0.button == button }) else { return nil }
                held.append(Hold(button: button, since: time))
                switch button {
                case .topLeft: return .command(.shuttleBack)
                case .topRight: return .command(.shuttleForward)
                default: return nil
                }
            }

            guard let index = held.firstIndex(where: { $0.button == button }) else { return nil }
            let hold = held.remove(at: index)
            guard !hold.usedForTurn else { return nil }
            let long = time - hold.since >= 0.5
            switch button {
            case .topMiddle: return .command(long ? .setSpeed(1) : .shuttleStop)
            case .sideUpperLeft: return long ? .edge(fromEnd: false) : .command(.playlistPrev)
            case .sideUpperRight: return long ? .edge(fromEnd: true) : .command(.playlistNext)
            case .bottomRight where long: return .command(.cycleMute)
            default: return nil
            }
        }
    }
}
