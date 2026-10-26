import CFFmpeg
import Foundation
import Testing
@testable import FrameScrubCore

/// Serialized: `forceFallbackForTesting` is global.
@Suite(.serialized) struct ClipWriterTests {
    /// A job for frames `a`...`b` of a fixture, timestamps from its exact index.
    private func job(_ name: String, a: Int, b: Int, exactKeyframe: Bool = true, directory: URL? = nil,
                     fallback: URL? = nil) throws -> ClipJob {
        try job(url: Fixtures.url(name), a: a, b: b, exactKeyframe: exactKeyframe, directory: directory, fallback: fallback)
    }

    private func job(url: URL, a: Int, b: Int, exactKeyframe: Bool = true, directory: URL? = nil,
                     fallback: URL? = nil) throws -> ClipJob {
        let index = try MediaSource(url: url).buildIndex()
        let dir = directory ?? makeTemporaryDirectory()
        let keyframe = index.keyframe(atOrBefore: a)
        return ClipJob(source: url, startPTS: index.pts(forFrame: a), endPTS: index.pts(forFrame: b),
                       keyframePTS: exactKeyframe ? index.pts(forFrame: keyframe) : nil,
                       directory: dir, fallbackDirectory: fallback ?? makeTemporaryDirectory(),
                       template: "%{video-name}_%{start}_%{end}", aFrame: a, aSeconds: index.seconds(forFrame: a),
                       endSeconds: index.seconds(forFrame: b), readLimit: 0)
    }

    /// A joined job: `ranges` (frame pairs) of a fixture, each from the keyframe at or before its start.
    private func joinedJob(_ name: String, ranges: [(Int, Int)]) throws -> ClipJob {
        let url = Fixtures.url(name)
        let index = try MediaSource(url: url).buildIndex()
        let (a, b) = (ranges.first!.0, ranges.last!.1)
        return ClipJob(source: url,
                       ranges: ranges.map { ClipRange(startPTS: index.pts(forFrame: $0.0), endPTS: index.pts(forFrame: $0.1),
                                                      keyframePTS: index.pts(forFrame: index.keyframe(atOrBefore: $0.0))) },
                       directory: makeTemporaryDirectory(), fallbackDirectory: makeTemporaryDirectory(),
                       template: "%{video-name}_%{start}_%{end}_joined", aFrame: a, aSeconds: index.seconds(forFrame: a),
                       endSeconds: index.seconds(forFrame: b), readLimit: 0)
    }

    /// Each stream's dts in file order.
    private func dtsByStream(_ url: URL) throws -> [Int32: [Int64]] {
        let source = try MediaSource(url: url)
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var result: [Int32: [Int64]] = [:]
        while source.read(into: packet!) >= 0 {
            result[packet!.pointee.stream_index, default: []].append(packet!.pointee.dts)
            av_packet_unref(packet!)
        }
        return result
    }

    /// `numbers` is each range's frames from its keyframe through its end, in order, each followed by at most two
    /// frames just past the end (the references written so frames up to the end decode; which ones depends on the
    /// GOP), and nothing twice.
    private func expectRanges(_ numbers: [Int], _ ranges: [ClosedRange<Int>], sourceLocation: SourceLocation = #_sourceLocation) {
        var rest = numbers[...]
        for range in ranges {
            #expect(Array(rest.prefix(range.count)) == Array(range), sourceLocation: sourceLocation)
            rest = rest.dropFirst(range.count)
            let extra = rest.prefix { $0 > range.upperBound && $0 <= range.upperBound + 4 }
            #expect(extra.count <= 2, sourceLocation: sourceLocation)
            rest = rest.dropFirst(extra.count)
        }
        #expect(rest.isEmpty && Set(numbers).count == numbers.count, sourceLocation: sourceLocation)
    }

    @Test func aClipIsNamedAfterThePagesSceneWhenGiven() throws {
        let plain = try job(Fixtures.h264, a: 300, b: 320)
        let named = SceneInfo(title: "A scene", code: "7").namingURL(for: URL(string: "http://h/stream/7")!)!
        let job = ClipJob(source: plain.source, nameSource: named, ranges: plain.ranges, directory: plain.directory,
                          fallbackDirectory: plain.fallbackDirectory, template: plain.template, aFrame: plain.aFrame,
                          aSeconds: plain.aSeconds, endSeconds: plain.endSeconds, readLimit: 0)
        let result = try ClipWriter.write(job, isCancelled: { false })
        #expect(result.url.lastPathComponent.hasPrefix("[7] A scene_"))
    }

    @Test func joinsTwoRangesFromDifferentGOPs() throws {
        let result = try ClipWriter.write(try joinedJob(Fixtures.h264, ranges: [(300, 320), (510, 530)]), isCancelled: { false })
        let (index, numbers) = try inspect(result.url)
        expectRanges(numbers, [250...320, 500...530])   // each range from its keyframe
        #expect(index.frameCount == numbers.count)
        #expect(abs(result.leadIn - 50.0 / 30) < 0.01)
        #expect(result.url.lastPathComponent.hasSuffix("_joined.mp4"))
    }

    @Test func joinedTimestampsKeepRising() throws {
        let result = try ClipWriter.write(try joinedJob(Fixtures.withAudioGOP25, ranges: [(30, 45), (80, 95)]), isCancelled: { false })
        for (_, dts) in try dtsByStream(result.url) {
            #expect(zip(dts, dts.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    @Test func joinsTwoRangesInOneGOPWithoutRepeats() throws {
        // clipRanges merges such segments; the writer copies the merged range once.
        let result = try ClipWriter.write(try joinedJob(Fixtures.h264, ranges: [(300, 340)]), isCancelled: { false })
        expectRanges(try inspect(result.url).1, [250...340])
    }

    @Test func joinedKeepsAudioWithinTheVideo() throws {
        let result = try ClipWriter.write(try joinedJob(Fixtures.withAudioGOP25, ranges: [(30, 45), (80, 95)]), isCancelled: { false })
        let numbers = try inspect(result.url).1
        #expect(numbers.first == 25 && numbers.contains(75) && !numbers.contains(60))
        let clip = try MediaSource(url: result.url)
        let audio = try #require(clip.audioStream)
        let audioDuration = Double(audio.pointee.duration) * av_q2d(audio.pointee.time_base)
        #expect(abs(audioDuration - clip.durationSeconds) < 0.15)
    }

    @Test func joinsRangesOfAnMKVWithBFrames() throws {
        // Matroska gives the packets right after a seek no dts; the second range must not reuse the first one's.
        let result = try ClipWriter.write(try joinedJob(Fixtures.withAudioGOP25MKV, ranges: [(30, 45), (80, 95)]), isCancelled: { false })
        #expect(result.url.pathExtension == "mkv")
        expectRanges(try inspect(result.url).1, [25...45, 75...95])
    }

    @Test func joinedFallsBackToMKV() throws {
        ClipWriter.forceFallbackForTesting = true
        defer { ClipWriter.forceFallbackForTesting = false }
        let result = try ClipWriter.write(try joinedJob(Fixtures.h264, ranges: [(300, 320), (510, 530)]), isCancelled: { false })
        #expect(result.url.pathExtension == "mkv")
        expectRanges(try inspect(result.url).1, [250...320, 500...530])
    }

    @Test(arguments: [Fixtures.rotated180, Fixtures.rotated90]) func clipsKeepTheDisplayRotation(name: String) throws {
        let rotation = try MediaSource(url: Fixtures.url(name)).rotationClockwise
        let clip = try ClipWriter.write(try job(name, a: 10, b: 30), isCancelled: { false })
        #expect(try MediaSource(url: clip.url).rotationClockwise == rotation)
        ClipWriter.forceFallbackForTesting = true
        defer { ClipWriter.forceFallbackForTesting = false }
        let fallback = try ClipWriter.write(try joinedJob(name, ranges: [(10, 30)]), isCancelled: { false })
        #expect(try MediaSource(url: fallback.url).rotationClockwise == rotation)
    }

    private func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// The clip's index and the numbers drawn in all of its frames, decoded in order.
    private func inspect(_ url: URL) throws -> (FrameIndex, [Int]) {
        let index = try MediaSource(url: url).buildIndex()
        let decoder = try VideoDecoder(source: try MediaSource(url: url), index: index)
        var numbers: [Int] = []
        while let frame = try decoder.nextFrame() { numbers.append(readFrameNumber(frame.pixelBuffer)) }
        return (index, numbers)
    }

    @Test func startsOnKeyframeBeforeA() throws {
        let job = try job(Fixtures.h264, a: 300, b: 400)
        let result = try ClipWriter.write(job, isCancelled: { false })
        #expect(result.url.pathExtension == "mp4")
        #expect(result.url.deletingLastPathComponent().standardizedFileURL == job.directory.standardizedFileURL)
        #expect(abs(result.leadIn - 50.0 / 30) < 0.01)
        let (index, numbers) = try inspect(result.url)
        // B + 2: frame 402 (a P frame) is stored before B-frames 399–401, which reference it, and 401's dts is
        // B's pts. Both are written so that every frame up to B decodes.
        #expect(index.frameCount == 153)
        #expect(index.isKeyframe(0))
        #expect(numbers == Array(250...402))
        #expect(try MediaSource(url: result.url).startPTS == 0)   // the first frame shows at zero
        #expect(files(in: job.directory) == [result.url.lastPathComponent])
    }

    @Test func approximateIndexSeeksBackward() throws {
        let job = try job(Fixtures.h264, a: 300, b: 400, exactKeyframe: false)
        let result = try ClipWriter.write(job, isCancelled: { false })
        let (index, numbers) = try inspect(result.url)
        #expect(index.frameCount == 153)   // B + 2, as in startsOnKeyframeBeforeA
        #expect(numbers == Array(250...402))
        #expect(abs(result.leadIn - 50.0 / 30) < 0.01)
    }

    @Test func aOnKeyframe() throws {
        let result = try ClipWriter.write(try job(Fixtures.h264, a: 250, b: 260), isCancelled: { false })
        #expect(result.leadIn == 0)
        #expect(try inspect(result.url).1 == Array(250...262))   // B + 2: the references of frames up to B
    }

    @Test func bIsLastFrame() throws {
        let result = try ClipWriter.write(try job(Fixtures.h264, a: 500, b: 599), isCancelled: { false })
        let (index, numbers) = try inspect(result.url)
        #expect(index.frameCount == 100)
        #expect(numbers == Array(500...599))
    }

    @Test func copiesAudio() throws {
        let result = try ClipWriter.write(try job(Fixtures.withAudio, a: 25, b: 74), isCancelled: { false })
        let clip = try MediaSource(url: result.url)
        let streams = (0..<Int(clip.formatContext.pointee.nb_streams)).map {
            clip.formatContext.pointee.streams[$0]!.pointee.codecpar.pointee.codec_type
        }
        #expect(streams.filter { $0 == AVMEDIA_TYPE_VIDEO }.count == 1)
        #expect(streams.filter { $0 == AVMEDIA_TYPE_AUDIO }.count == 1)
        let audio = try #require(clip.audioStream)
        let audioDuration = Double(audio.pointee.duration) * av_q2d(audio.pointee.time_base)
        #expect(abs(audioDuration - clip.durationSeconds) < 0.1)
        // Audio reaches the end of the last video frame (B + 2, frames 0…76) although it is stored after it.
        #expect(try MediaSource(url: result.url).buildIndex().frameCount == 77)
        #expect(audioDuration >= 77.0 / 25 - 0.025)
        #expect(clip.startPTS == 0 && audio.pointee.start_time == 0)
    }

    @Test func dropsLeadingPicturesOfOpenGOP() throws {
        let result = try ClipWriter.write(try job(Fixtures.hevc10, a: 60, b: 90), isCancelled: { false })
        let clip = try MediaSource(url: result.url)
        let packet = try #require(av_packet_alloc())
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        var packets = 0
        while clip.read(into: packet) >= 0 {
            #expect(packet.pointee.pts >= 0)
            packets += 1
            av_packet_unref(packet)
        }
        // 60…90 plus 91 and 95: hierarchical B-frames up to 90 reference them (92–94 are not needed and stay out).
        #expect(packets == 33)
        let (index, numbers) = try inspect(result.url)
        #expect(index.frameCount == 33)
        #expect(numbers == Array(60...91) + [95])   // every frame decodes, in order
    }

    @Test func mkvSourceStaysMkv() throws {
        let result = try ClipWriter.write(try job(Fixtures.av1, a: 10, b: 40), isCancelled: { false })
        #expect(result.url.pathExtension == "mkv")
        // Keyframes 0/60, no B-frames: exactly 0…40.
        #expect(try inspect(result.url).1 == Array(0...40))
    }

    /// Matroska stores no dts: the demuxer guesses them for H.264 with B-frames, except for the first packets.
    @Test func mkvWithBFramesEndsNearB() throws {
        ClipWriter.forceFallbackForTesting = true
        let mkv: ClipResult
        do {
            defer { ClipWriter.forceFallbackForTesting = false }   // the second write below is a plain mkv source
            mkv = try ClipWriter.write(try job(Fixtures.h264, a: 300, b: 400), isCancelled: { false })
        }
        #expect(try inspect(mkv.url).1 == Array(250...402))
        let source = try MediaSource(url: mkv.url)
        let packet = try #require(av_packet_alloc())
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        #expect(source.read(into: packet) >= 0 && packet.pointee.dts == cff_nopts())
        av_packet_unref(packet)

        // Frames 10…60 of the mkv (fixture numbers 260…310); the start is its keyframe 0 (250).
        let result = try ClipWriter.write(try job(url: mkv.url, a: 10, b: 60), isCancelled: { false })
        let numbers = try inspect(result.url).1
        // Up to B plus at most the 1 s margin (30 frames): never the rest of the file (402).
        #expect(Array(numbers.prefix(61)) == Array(250...310))
        #expect(numbers.count <= 61 + 30 && numbers.last! <= 310 + 30)
    }

    @Test func videoEndRule() {
        let none = cff_nopts()
        func action(pts: Int64, dts: Int64) -> ClipWriter.VideoAction {
            ClipWriter.videoAction(pts: pts, dts: dts, start: 100, end: 200, margin: 30)
        }
        #expect(action(pts: 90, dts: 80) == .skip)     // leading picture before the start keyframe
        #expect(action(pts: 230, dts: 200) == .write)  // a reference after B, stored before frames up to B
        #expect(action(pts: 210, dts: 201) == .stop)
        // No dts: judged by pts, bounded by the margin.
        #expect(action(pts: 150, dts: none) == .write)
        #expect(action(pts: 230, dts: none) == .write)
        #expect(action(pts: 231, dts: none) == .stop)
        // A dts that never passes B still writes nothing past the margin.
        #expect(action(pts: 260, dts: 190) == .skip)
        #expect(action(pts: none, dts: 150) == .write)
        #expect(action(pts: none, dts: none) == .skip)
    }

    @Test func audioReadAheadOfVideo() throws {
        let result = try ClipWriter.write(try job(Fixtures.audioLead, a: 25, b: 74), isCancelled: { false })
        let clip = try MediaSource(url: result.url)
        let audio = try #require(clip.audioStream)
        let audioDuration = Double(audio.pointee.duration) * av_q2d(audio.pointee.time_base)
        let numbers = try inspect(result.url).1
        // Up to B plus the references written with it (75 and 77; 76 is not needed).
        #expect(numbers == Array(0...75) + [77])
        #expect(audioDuration >= 78.0 / 25 - 0.025 && audioDuration < 78.0 / 25 + 0.1)
        #expect(audio.pointee.start_time == 0)
    }

    @Test func fallsBackToMkv() throws {
        ClipWriter.forceFallbackForTesting = true
        defer { ClipWriter.forceFallbackForTesting = false }
        let job = try job(Fixtures.h264, a: 300, b: 400)
        let result = try ClipWriter.write(job, isCancelled: { false })
        #expect(result.url.pathExtension == "mkv")
        let (index, numbers) = try inspect(result.url)
        #expect(index.frameCount == 153)   // B + 2, as in startsOnKeyframeBeforeA
        #expect(numbers == Array(250...402))
        #expect(files(in: job.directory) == [result.url.lastPathComponent])
    }

    @Test func nameTaken() throws {
        let job = try job(Fixtures.h264, a: 250, b: 260)
        let first = try ClipWriter.write(job, isCancelled: { false })
        let second = try ClipWriter.write(job, isCancelled: { false })
        let base = first.url.deletingPathExtension().lastPathComponent
        #expect(second.url.lastPathComponent == "\(base) 2.mp4")
        #expect(Set(files(in: job.directory)) == [first.url.lastPathComponent, second.url.lastPathComponent])
    }

    @Test func cancelRemovesPart() throws {
        let job = try job(Fixtures.h264, a: 300, b: 400)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ClipWriter.write(job, isCancelled: { checks += 1; return checks > 10 })
        }
        #expect(files(in: job.directory).isEmpty)
    }

    @Test func unwritableDirectoryFallsBack() throws {
        let locked = makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let fallback = makeTemporaryDirectory().appendingPathComponent("clips", isDirectory: true)
        let job = try job(Fixtures.h264, a: 250, b: 260, directory: locked.appendingPathComponent("frames"),
                          fallback: fallback)
        let result = try ClipWriter.write(job, isCancelled: { false })
        #expect(result.url.deletingLastPathComponent().standardizedFileURL == fallback.standardizedFileURL)
        #expect(try MediaSource(url: result.url).buildIndex().frameCount == 13)   // B + 2, as in aOnKeyframe
    }
}
