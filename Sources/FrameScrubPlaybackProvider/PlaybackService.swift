import Foundation

let sceneID = "player"
let providerID = "local.framescrub.playback"
let playbackVersion = 6

@objc protocol PlaybackService {
    func handshake(_ reply: @escaping (Int, Int32) -> Void)
    func open(_ readOnlyFile: FileHandle, reply: @escaping (String) -> Void)
    func step(_ count: Int, reply: @escaping (String) -> Void)
    func play()
    func pause()
    func togglePlayback()
    func togglePlaybackColor(_ automatic: Bool)
    func seek(_ seconds: Double, reply: @escaping (String) -> Void)
    func close()
    func playbackTime(_ reply: @escaping (Double) -> Void)
    func status(_ reply: @escaping (String) -> Void)
    func playbackKeys(_ reply: @escaping ([String]) -> Void)
    func playbackKey(_ keyCode: UInt16, characters: String, flags: UInt, repeating: Bool)
    func playbackScroll(_ x: Double, y: Double, time: Double, flags: UInt,
                        precise: Bool, began: Bool, phased: Bool, momentum: Bool, notches: UInt16,
                        reply: @escaping () -> Void)
    func cancelPlaybackScroll()
}
