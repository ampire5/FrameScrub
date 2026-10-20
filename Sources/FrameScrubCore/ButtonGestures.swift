import Foundation

/// Press recognition for the mouse buttons `input.conf` binds besides the left and right ones (port of Loupe's
/// `ButtonGestures`): a pure state machine with injected time. The caller feeds it presses, releases, wheel events,
/// pointer movement and timer ticks; it answers with the chords that fired (`MX_PANEL`, `MBTN_BACK_LONG`,
/// `MBTN_FORWARD_DBL`, `MBTN_RIGHT+MBTN_MID`) and, for a wheel event, the held-button modifier its chord gets.
///
/// - A button with only a tap binding fires on the press.
/// - With a `_LONG`, `_DBL` or chord binding (`MBTN_BACK+WHEEL_UP`: the button held) the tap fires on the release,
///   unless a wheel event, a drift of `driftPoints` or the long press cancelled it.
/// - `_DBL`: the release starts a `doubleInterval` wait; a second press inside it fires `<b>_DBL` and nothing else,
///   another button's press or the expiry fires the single.
/// - `_LONG`: without chords the timer (`tick`) fires it at the deadline; with chords the hold usually means "now I
///   will scroll", so it fires on a release after the deadline, and `tick` reports it `armed` once at the deadline.
/// - With the right button held (`rightHeld`) and a `MBTN_RIGHT+<b>` binding, that chord fires on the press and the
///   press takes no part in anything else.
///
/// Fired chords carry the keyboard modifiers of their press. Nothing here touches AppKit or a timer: the caller arms
/// one for `nextDeadline` and calls `tick`.
public struct ButtonGestures: Sendable {
    /// Travel, in points, on either axis since a press that makes it a drag, not a press (cancels tap and long).
    public static let driftPoints = 8.0
    /// A wheel gap of this many seconds ends the scroll tail that keeps a released button's modifier.
    public static let absorbGap = 0.25

    private struct Kinds {
        var tap = false, long = false, double = false, chords = false, withRight = false
    }

    private struct Press {
        let seq: Int
        let keys: Modifiers
        /// When a long press fires: always compared as `t >= deadline`, never as a difference of times.
        let deadline: Double
        /// A wheel event, the drift or a long press happened: the release does not tap.
        var cancelled = false
        var longFired = false
        /// The deadline passed on a long-on-release press that could still count.
        var armed = false
        /// A right chord or a double: it already fired and takes no part in anything else.
        var dead = false
        var moveX = 0.0
        var moveY = 0.0
    }

    /// A released single tap waiting `doubleInterval` for a second press.
    private struct Wait {
        let seq: Int
        let keys: Modifiers
        let deadline: Double
    }

    private let kinds: [MouseButton: Kinds]
    private let longPress: Double
    private let doubleInterval: Double
    private var presses: [MouseButton: Press] = [:]
    private var waits: [MouseButton: Wait] = [:]
    private var sequence = 0
    /// The modifier wheel events keep getting after the release of the button that took a scroll (see `wheel`).
    private var absorbing: Modifiers = []
    private var lastAbsorbed = 0.0

    /// `longPress` and `doubleInterval` in seconds.
    public init(map: InputMap, longPress: Double, doubleInterval: Double) {
        var kinds: [MouseButton: Kinds] = [:]
        for b in MouseButton.allCases {
            let k = Kinds(tap: map.binds(b), long: map.binds(b, suffix: "_LONG"), double: map.binds(b, suffix: "_DBL"),
                          chords: map.hasChords(heldWith: b),
                          withRight: map.command(for: KeyChord(key: b.rawValue, modifiers: .rightButton)) != nil)
            if k.tap || k.long || k.double || k.chords || k.withRight { kinds[b] = k }
        }
        self.kinds = kinds
        self.longPress = longPress
        self.doubleInterval = doubleInterval
    }

    /// The buttons pressed and not released (only bound ones are tracked).
    public var held: Set<MouseButton> { Set(presses.keys) }

    private func kind(_ b: MouseButton) -> Kinds { kinds[b] ?? Kinds() }

    /// A tap that fires on the press itself: nothing else is bound to the button (besides the right chord).
    private func firesOnPress(_ b: MouseButton) -> Bool {
        let k = kind(b)
        return k.tap && !k.long && !k.double && !k.chords
    }

    private func chord(_ b: MouseButton, _ keys: Modifiers, _ suffix: String = "") -> KeyChord {
        KeyChord(key: b.rawValue + suffix, modifiers: keys)
    }

    /// A long press is still possible: bound, and nothing cancelled it or fired it yet.
    private func longPossible(_ b: MouseButton, _ p: Press) -> Bool {
        kind(b).long && !p.cancelled && !p.longFired && !p.dead
    }

    /// A button with chords fires its long press on release, not at the deadline (see the type's comment).
    private func longOnRelease(_ b: MouseButton) -> Bool { kind(b).chords }

    /// A long press the timer must fire at its deadline.
    private func isPending(_ b: MouseButton, _ p: Press) -> Bool { longPossible(b, p) && !longOnRelease(b) }

    /// A long-on-release press whose deadline has yet to be reported as `armed`.
    private func awaitsArming(_ b: MouseButton, _ p: Press) -> Bool { longPossible(b, p) && longOnRelease(b) && !p.armed }

    /// Fires the waiting singles of the buttons other than `b`, oldest first.
    private mutating func flushWaits(except b: MouseButton? = nil) -> [KeyChord] {
        let flushed = waits.filter { $0.key != b }.sorted { $0.value.seq < $1.value.seq }
        for (button, _) in flushed { waits[button] = nil }
        return flushed.compactMap { kind($0.key).tap ? chord($0.key, $0.value.keys) : nil }
    }

    /// `keys`: the keyboard modifiers at the press; `rightHeld`: the right button is down (fires `MBTN_RIGHT+<b>`).
    public mutating func press(_ b: MouseButton, keys: Modifiers, rightHeld: Bool, at t: Double) -> [KeyChord] {
        guard presses[b] == nil, let k = kinds[b] else { return [] }
        var fired = flushWaits(except: b)
        sequence += 1
        var p = Press(seq: sequence, keys: keys, deadline: t + longPress)
        // The right chord comes before the double: with the right button held, a second press inside the double
        // interval is `MBTN_RIGHT+<b>`, and the first press's waiting single fires on its own.
        if k.withRight, rightHeld {
            if let wait = waits.removeValue(forKey: b), k.tap { fired.append(chord(b, wait.keys)) }
            p.dead = true
            presses[b] = p
            return fired + [chord(b, keys.union(.rightButton))]
        }
        if let wait = waits.removeValue(forKey: b) {
            if wait.keys == keys, t < wait.deadline {
                p.dead = true
                presses[b] = p
                return fired + [chord(b, keys, "_DBL")]
            }
            if k.tap { fired.append(chord(b, wait.keys)) }
        }
        if firesOnPress(b) {
            p.cancelled = true
            presses[b] = p
            return fired + [chord(b, keys)]
        }
        presses[b] = p
        return fired
    }

    public mutating func release(_ b: MouseButton, at t: Double) -> [KeyChord] {
        guard let p = presses.removeValue(forKey: b) else { return [] }
        // A timer-driven long press whose timer ran late, or one that waits for the release.
        if longPossible(b, p), t >= p.deadline { return [chord(b, p.keys, "_LONG")] }
        guard !p.cancelled, !p.dead else { return [] }
        if kind(b).double {
            waits[b] = Wait(seq: p.seq, keys: p.keys, deadline: t + doubleInterval)
            return []
        }
        return kind(b).tap ? [chord(b, p.keys)] : []
    }

    /// Fires every long press that is due and every double wait that ran out (its single), once each, oldest press
    /// first, and reports once each long-on-release press that has just become armed (`armed`): it fires nothing, the
    /// release does, and a wheel event or a drift before then means it never arms.
    public mutating func tick(at t: Double) -> (fires: [KeyChord], armed: [MouseButton]) {
        var out: [(Int, KeyChord)] = []
        var armed: [(Int, MouseButton)] = []
        for (b, p) in presses where t >= p.deadline {
            if isPending(b, p) {
                presses[b]!.longFired = true
                presses[b]!.cancelled = true
                out.append((p.seq, chord(b, p.keys, "_LONG")))
            } else if awaitsArming(b, p) {
                presses[b]!.armed = true
                armed.append((p.seq, b))
            }
        }
        for (b, w) in waits where t >= w.deadline {
            waits[b] = nil
            if kind(b).tap { out.append((w.seq, chord(b, w.keys))) }
        }
        return (out.sorted { $0.0 < $1.0 }.map(\.1), armed.sorted { $0.0 < $1.0 }.map(\.1))
    }

    /// When `tick` next has something to do, or nil: a long press the timer fires, a long-on-release one not yet armed,
    /// or a double wait that runs out.
    public var nextDeadline: Double? {
        let long = presses.filter { isPending($0.key, $0.value) || awaitsArming($0.key, $0.value) }.map(\.value.deadline)
        return (long + waits.values.map(\.deadline)).min()
    }

    /// A wheel event: the held-button modifier to add to its chord ([] = none). It goes to the last-pressed held button
    /// with chords. A non-momentum event with a delta cancels the tap and long press of every held button (a
    /// non-momentum one without, of the button it goes to); a momentum event cancels nothing: a press made while an
    /// earlier scroll still coasts must fire. After the release of the button the scroll went to, the tail of that
    /// scroll keeps its modifier until a gap of `absorbGap` seconds between events.
    public mutating func wheel(hasDelta: Bool, momentum: Bool, at t: Double) -> Modifiers {
        if !momentum, hasDelta {
            for b in Array(presses.keys) { presses[b]!.cancelled = true }
        }
        let target = presses.filter { !$0.value.dead && kind($0.key).chords }.max { $0.value.seq < $1.value.seq }?.key
        guard let b = target, let modifier = b.modifier else {
            guard !absorbing.isEmpty else { return [] }
            if t - lastAbsorbed >= Self.absorbGap { absorbing = []; return [] }
            lastAbsorbed = t
            return absorbing
        }
        if !momentum { presses[b]!.cancelled = true }
        absorbing = modifier
        lastAbsorbed = t
        return modifier
    }

    /// Pointer movement in points: travel of `driftPoints` on either axis since its own press cancels a held button's
    /// tap and long press (a press that moved that far was a drag).
    public mutating func move(dx: Double, dy: Double) {
        for b in Array(presses.keys) {
            presses[b]!.moveX += dx
            presses[b]!.moveY += dy
            if max(abs(presses[b]!.moveX), abs(presses[b]!.moveY)) >= Self.driftPoints { presses[b]!.cancelled = true }
        }
    }

    /// Forgets everything in flight without firing: the app lost focus or the window went away mid-press.
    public mutating func cancelAll() {
        presses = [:]
        waits = [:]
        absorbing = []
    }
}
