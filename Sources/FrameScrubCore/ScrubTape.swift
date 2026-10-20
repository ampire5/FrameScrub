import AVFoundation
import os
import QuartzCore

/// The tape (scrub audio spec §6а): an `AVAudioSourceNode` that reads the latest `TapeSnapshot` at the position
/// `TapeMotion` gives for every output sample, so the sound follows the frame on screen with the pitch of a tape —
/// or, with `pitch == .natural`, through `GrainStretcher` at the sound's own pitch (spec §6б).
/// The render thread never waits: it takes the control and snapshot with a try-lock and keeps its last copy otherwise.
public final class ScrubTape: TapeSink, @unchecked Sendable {
    private final class Shared: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock()
        var control = TapeControl(target: 0, shownAt: -1, frameVelocity: 0, running: false)
        var snapshot: TapeSnapshot?
        /// Snapshots the render thread may still hold, kept alive by the writer so the render thread never frees
        /// one (~1.5 MB of arrays): they are released by the next `setTapeSnapshot`, off the audio thread.
        var retired: [TapeSnapshot] = []
        // Render thread only (written under the lock when swapped).
        var motion = TapeMotion()
        var renderControl = TapeControl(target: 0, shownAt: -1, frameVelocity: 0, running: false)
        var renderSnapshot: TapeSnapshot?
        var fadingSnapshot: TapeSnapshot?   // the one before, crossfaded out over `crossfade` samples
        var crossfadeLeft = 0
        var stretcher: GrainStretcher
        var renderPitch = ScrubPitch.tape
        var fadingPitch = ScrubPitch.tape     // the mode before a switch, crossfaded out over `crossfade` samples
        var pitchFadeLeft = 0

        init(sampleRate: Double) { stretcher = GrainStretcher(sampleRate: sampleRate) }
    }

    public let node: AVAudioSourceNode
    private let shared: Shared

    public init(format: AVAudioFormat) {
        let shared = Shared(sampleRate: format.sampleRate)
        let dt = 1 / format.sampleRate
        let crossfade = max(1, Int((0.003 * format.sampleRate).rounded()))
        self.shared = shared
        node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            if shared.lock.lockIfAvailable() {
                shared.renderControl = shared.control
                if shared.snapshot !== shared.renderSnapshot {
                    shared.fadingSnapshot = shared.renderSnapshot
                    shared.renderSnapshot = shared.snapshot
                    shared.crossfadeLeft = crossfade
                }
                shared.lock.unlock()
            }
            if shared.renderControl.pitch != shared.renderPitch {
                // A switch mid-scrub: grains start afresh and the old mode fades out (spec §6б).
                if shared.renderControl.pitch == .natural { shared.stretcher.restart() }
                shared.fadingPitch = shared.renderPitch
                shared.renderPitch = shared.renderControl.pitch
                shared.pitchFadeLeft = crossfade
            }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            let control = shared.renderControl
            let snapshot = shared.renderSnapshot
            let fading = shared.fadingSnapshot
            var now = CACurrentMediaTime()
            var heard = false
            for i in 0..<frames {
                let at = shared.motion.step(dt: dt, now: now, control: control)
                let gain = shared.motion.gain
                var l: Float = 0, r: Float = 0
                if gain == 0 { shared.stretcher.restart() }   // silent or jumping: grains start afresh at the new place
                if gain > 0, let snapshot {
                    let k = Float(shared.crossfadeLeft) / Float(crossfade)
                    func read(_ t: Double) -> (Float, Float) {
                        var (l, r) = snapshot.sample(atSeconds: t)
                        if k > 0 {
                            // A new snapshot (more sound decoded): crossfade from the old one instead of jumping.
                            let (ol, or) = fading?.sample(atSeconds: t) ?? (0, 0)
                            l = l * (1 - k) + ol * k
                            r = r * (1 - k) + or * k
                        }
                        return (l, r)
                    }
                    func sound(_ pitch: ScrubPitch) -> (Float, Float) {
                        pitch == .natural
                            ? shared.stretcher.next(position: at, velocity: shared.motion.velocity, read: read)
                            : read(at)
                    }
                    (l, r) = sound(shared.renderPitch)
                    if shared.pitchFadeLeft > 0 {
                        let m = Float(shared.pitchFadeLeft) / Float(crossfade)
                        let (ol, or) = sound(shared.fadingPitch)
                        l = l * (1 - m) + ol * m
                        r = r * (1 - m) + or * m
                    }
                    l *= gain
                    r *= gain
                    heard = true
                }
                if shared.crossfadeLeft > 0 { shared.crossfadeLeft -= 1 }
                if shared.pitchFadeLeft > 0 { shared.pitchFadeLeft -= 1 }
                left?[i] = l
                right?[i] = r
                now += dt
            }
            isSilence.pointee = ObjCBool(!heard)
            return noErr
        }
    }

    public func setTapeSnapshot(_ snapshot: TapeSnapshot) {
        let released = shared.lock.withLock { () -> [TapeSnapshot] in
            let old = shared.retired
            shared.retired = [shared.snapshot, shared.renderSnapshot, shared.fadingSnapshot].compactMap { $0 }
            shared.snapshot = snapshot
            return old
        }
        _ = released   // freed here, on the writer's thread
    }

    public func setTapeControl(_ control: TapeControl) {
        shared.lock.withLock { shared.control = control }
    }
}
