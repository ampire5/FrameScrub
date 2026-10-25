import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PluginRequestsTests {
    private func message(_ json: [String: Any]) -> PluginMessage? { PluginMessage(json: json) }
    private func reason(_ json: [String: Any]) -> String? {
        if case let .failure(failure) = PluginMessage.parse(json) { return failure.reason }
        return nil
    }

    @Test func plainRequests() {
        #expect(message(["cmd": "info"]) == .info)
        #expect(message(["cmd": "marks"]) == .marks)
        #expect(message(["cmd": "playlist"]) == .playlist)
    }

    @Test func frameRequestTakesATimeOrAFrame() {
        #expect(message(["cmd": "frame", "t": 1.5]) == .frame(PluginFrameRequest(position: .seconds(1.5))))
        #expect(message(["cmd": "frame", "frame": 37]) == .frame(PluginFrameRequest(position: .frame(37))))
        #expect(message(["cmd": "frame", "frame": 37, "maxSize": 128])
                == .frame(PluginFrameRequest(position: .frame(37), maxSize: 128)))
        #expect(message(["cmd": "frame", "t": 0, "maxSize": 4096])
                == .frame(PluginFrameRequest(position: .seconds(0), maxSize: 512)))   // capped
        #expect(message(["cmd": "frame", "t": 0, "maxSize": 1e300])
                == .frame(PluginFrameRequest(position: .seconds(0), maxSize: 512)))   // capped, not trapped
        #expect(reason(["cmd": "frame"]) == "frame: t or frame is missing")
        #expect(reason(["cmd": "frame", "t": 1, "frame": 2]) == "frame: t or frame, not both")
        #expect(reason(["cmd": "frame", "t": -1]) == "frame: t must not be negative")
        #expect(reason(["cmd": "frame", "frame": -1]) == "frame: frame is out of range")
        #expect(reason(["cmd": "frame", "frame": "7"]) == "frame: frame must be a number")
        #expect(reason(["cmd": "frame", "frame": 7, "maxSize": 8]) == "frame: maxSize must be at least 16")
        #expect(reason(["cmd": "frame", "frame": 7, "maxSize": "big"]) == "frame: maxSize must be a number")
    }

    @Test func frameNumberWithinTheFile() {
        let bySeconds = { (seconds: Double) in Int((seconds * 25).rounded()) }
        #expect(PluginFrameRequest(position: .frame(99)).frameNumber(frameCount: 100, frameForSeconds: bySeconds) == 99)
        #expect(PluginFrameRequest(position: .frame(100)).frameNumber(frameCount: 100, frameForSeconds: bySeconds) == nil)
        #expect(PluginFrameRequest(position: .seconds(2)).frameNumber(frameCount: 100, frameForSeconds: bySeconds) == 50)
        #expect(PluginFrameRequest(position: .seconds(4)).frameNumber(frameCount: 100, frameForSeconds: bySeconds) == nil)
        #expect(PluginFrameRequest(position: .frame(0)).frameNumber(frameCount: 0, frameForSeconds: bySeconds) == nil)
    }

    @Test func infoJSON() {
        let info = PluginInfo(path: "/a/b.mp4", name: "b.mp4", fps: 25, duration: 4, durationFrames: 100, width: 640,
                              height: 360, rotation: 0, codec: "h264")
        #expect(info.json == """
        {"codec":"h264","duration":4,"durationFrames":100,"fps":25,"height":360,"name":"b.mp4","path":"/a/b.mp4",\
        "rotation":0,"source":"file","width":640}
        """)
        #expect(PluginJSON.decode(PluginInfo.self, from: info.json!) == info)
    }

    @Test func marksFromThePlayersMarks() {
        var cut = CutMarks()
        _ = cut.add(CutSegment(start: 10, end: 20))
        _ = cut.add(CutSegment(start: 50, end: 60))
        _ = cut.markIn(at: 80)
        let marks = PluginMarks(marks: cut, loopA: 25, loopB: 75, seconds: { Double($0) / 25 })
        #expect(marks.loop == [1, 3])
        #expect(marks.loopFrames == [25, 75])
        #expect(marks.segments == [
            PluginMarks.Segment(start: 0.4, end: 0.8, startFrame: 10, endFrame: 20),
            PluginMarks.Segment(start: 2, end: 2.4, startFrame: 50, endFrame: 60),
        ])
        #expect(marks.openFrame == 80)
        #expect(marks.openStart == 3.2)
        #expect(marks.json == """
        {"loop":[1,3],"loopFrames":[25,75],"openFrame":80,"openStart":3.2,"segments":[{"end":0.8,"endFrame":20,\
        "start":0.4,"startFrame":10},{"end":2.4,"endFrame":60,"start":2,"startFrame":50}]}
        """)
    }

    @Test func marksWithoutAnything() {
        let marks = PluginMarks(marks: CutMarks(), loopA: nil, loopB: nil, seconds: { Double($0) })
        #expect(marks.json == #"{"loop":null,"loopFrames":null,"openFrame":null,"openStart":null,"segments":[]}"#)
        // A alone is not a range yet.
        #expect(PluginMarks(marks: CutMarks(), loopA: 5, loopB: nil, seconds: { Double($0) }).loop == nil)
    }

    @Test func playlistJSON() {
        #expect(PluginPlaylist(index: 11, count: 48, total: 50, name: "a.mp4").json
                == #"{"count":48,"index":11,"name":"a.mp4","source":"folder","total":50}"#)
    }

    @Test func playlistReplyHasSource() {
        #expect(PluginPlaylist(index: 0, count: 3, total: 3, name: "Chapters", source: .list).json?
            .contains(#""source":"list""#) == true)
    }

    @Test func frameJSONCarriesADataURL() {
        let frame = PluginFrame(t: 1.5, frame: 37, width: 128, height: 72, jpeg: Data([0xFF, 0xD8, 0xFF]))
        #expect(frame.json == #"{"dataURL":"data:image/jpeg;base64,/9j/","frame":37,"height":72,"t":1.5,"width":128}"#)
    }

    @Test func grabsOneFrameAsAFittedJPEG() async throws {
        let (source, index) = try openIndexed(Fixtures.withAudioGOP25)   // 640x360, keyframes every 25
        let grabber = PluginFrameGrabber(url: source.url, index: index, rotationClockwise: 0)
        let picture = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PluginFrameGrabber.Picture, Error>) in
            grabber.grab(frame: 37, maxSide: 128) { continuation.resume(with: $0) }
        }
        #expect(picture.frame == 37)
        #expect(picture.size == CGSize(width: 128, height: 72))
        #expect(picture.jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(index.seconds(forPTS: picture.pts) == index.seconds(forFrame: 37))
        grabber.stop()
        let afterStop = await withCheckedContinuation { (continuation: CheckedContinuation<Result<PluginFrameGrabber.Picture, PluginFrameGrabber.Failure>, Never>) in
            grabber.grab(frame: 1, maxSide: 64) { continuation.resume(returning: $0) }
        }
        #expect(afterStop == .failure(.stopped))
    }
}
