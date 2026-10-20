import Foundation
import CoreImage
import ImageIO
import Testing
@testable import FrameScrubCore

private final class FlagBox: @unchecked Sendable { var flag: CancellationFlag? }

@Suite struct FrameExportTests {
    private func decodeFrame(_ name: String, _ n: Int) throws -> (MediaSource, FrameIndex, DecodedFrame) {
        let (source, index) = try openIndexed(name)
        let decoder = try VideoDecoder(source: source, index: index)
        try decoder.seek(toFrame: n)
        return (source, index, try #require(try decoder.nextFrame()))
    }

    private func exporter(for video: URL, format: ImageFormat = .jpeg, root: URL, screen: CGSize? = nil,
                          configure: (inout Config) -> Void = { _ in }) -> FrameExporter {
        var config = Config()
        config.frameFormat = format
        config.frameDirectory = root.path + "/%{video-name}"
        configure(&config)
        return FrameExporter(videoURL: video, rotationClockwise: 0,
                             settings: ExportSettings(config: config, fallbackRoot: root.appendingPathComponent("fallback"),
                                                  screenPixels: screen))
    }

    private func save(_ exporter: FrameExporter, _ frame: DecodedFrame, seconds: Double) async throws -> SavedFrame {
        try await withCheckedThrowingContinuation { continuation in
            exporter.saveFrame(frame, seconds: seconds) { continuation.resume(with: $0) }
        }
    }

    @Test func copyFrameProducesAnSRGBPNGAtTheSaveSize() async throws {
        let (source, _, frame) = try decodeFrame(Fixtures.h264, 42)
        let copier = exporter(for: source.url, root: makeTemporaryDirectory()) { $0.saveScale = 2; $0.saveUpscaler = .lanczos }
        let copied = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CopiedFrame, Error>) in
            copier.copyFrame(frame) { c.resume(with: $0) }
        }
        #expect(copied.fallbackReason == nil)
        #expect(copied.data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))   // PNG signature
        let image = try #require(CGImageSourceCreateWithData(copied.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 3840 && image.height == 2160)
    }

    @Test func savedAndCopiedFramesAreCroppedAndStretchedLikeTheScreen() async throws {
        let (source, _, frame) = try decodeFrame(Fixtures.anamorphic, 12)
        let geometry = DisplayGeometry(crop: CGRect(x: 0, y: 88.0 / 576, width: 1, height: 400.0 / 576), pixelAspect: source.sampleAspect)
        let root = makeTemporaryDirectory()
        let saver = FrameExporter(videoURL: source.url, rotationClockwise: 0,
                                  settings: ExportSettings(config: Config(), fallbackRoot: root, geometry: geometry))
        let copied = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CopiedFrame, Error>) in
            saver.copyFrame(frame) { c.resume(with: $0) }
        }
        let image = try #require(CGImageSourceCreateWithData(copied.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 1024 && image.height == 400)
        var config = Config()
        config.frameFormat = .png
        config.frameDirectory = root.path + "/%{video-name}"
        let saved = try await save(FrameExporter(videoURL: source.url, rotationClockwise: 0,
                                                 settings: ExportSettings(config: config, fallbackRoot: root, geometry: geometry)),
                                   frame, seconds: 0.48)
        let properties = imageProperties(saved.url)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 400)
    }

    @Test func copyFrameToneMapsHDRAndAppliesRotation() async throws {
        let (source, _, frame) = try decodeFrame(Fixtures.rotated, 5)
        let copier = FrameExporter(videoURL: source.url, rotationClockwise: source.rotationClockwise,
                                   settings: ExportSettings(config: Config()))
        let copied = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CopiedFrame, Error>) in
            copier.copyFrame(frame) { c.resume(with: $0) }
        }
        let image = try #require(CGImageSourceCreateWithData(copied.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 360 && image.height == 640)
        let (_, _, hdr) = try decodeFrame(Fixtures.hevc10, 10)
        let hdrCopy = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CopiedFrame, Error>) in
            exporter(for: Fixtures.url(Fixtures.hevc10), root: makeTemporaryDirectory()).copyFrame(hdr) { c.resume(with: $0) }
        }
        #expect(hdrCopy.data.count > 1000)
    }

    @Test func copyFrameAppliesTheColorCorrectionOnlyWhenAsked() async throws {
        let (source, _, frame) = try decodeFrame(Fixtures.rotated, 5)
        func copy(saveColor: Bool) async throws -> Data {
            var config = Config()
            config.saveColor = saveColor
            let copier = FrameExporter(videoURL: source.url, rotationClockwise: source.rotationClockwise,
                                       settings: ExportSettings(config: config, color: ColorCorrection(vibrance: 1)))
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CopiedFrame, Error>) in
                copier.copyFrame(frame) { c.resume(with: $0) }
            }.data
        }
        let plain = try await copy(saveColor: false)
        let original = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CopiedFrame, Error>) in
            FrameExporter(videoURL: source.url, rotationClockwise: source.rotationClockwise,
                          settings: ExportSettings(config: Config())).copyFrame(frame) { c.resume(with: $0) }
        }.data
        #expect(plain == original)
        #expect(try await copy(saveColor: true) != original)
    }

    @Test func savesJPEGAtNativeResolution() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.h264, 42)
        let root = makeTemporaryDirectory()
        let saved = try await save(exporter(for: source.url, root: root), frame, seconds: index.seconds(forFrame: 42))
        #expect(saved.url.lastPathComponent == "h264_cfr_gop250_f000042_00-00-01.400.jpg")
        #expect(saved.url.deletingLastPathComponent().path == root.appendingPathComponent("h264_cfr_gop250").path)
        #expect(!saved.usedFallbackDirectory)
        let properties = imageProperties(saved.url)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1920)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1080)
        #expect(properties[kCGImagePropertyDepth] as? Int == 8)
        #expect(readFrameNumber(imageAt: saved.url) == 42)
    }

    @Test func hlgSourceGivesSDRJPEGAndHighBitDepthHEICAndPNG() throws {
        let (_, _, frame) = try decodeFrame(Fixtures.hevc10, 10)
        let root = makeTemporaryDirectory()
        let renderer = FrameImageRenderer()
        let jpeg = root.appendingPathComponent("a.jpg")
        let heic = root.appendingPathComponent("a.heic")
        let png = root.appendingPathComponent("a.png")
        try renderer.write(frame, rotationClockwise: 0, format: .jpeg, quality: 95, to: jpeg)
        try renderer.write(frame, rotationClockwise: 0, format: .heic, quality: 95, to: heic)
        try renderer.write(frame, rotationClockwise: 0, format: .png, quality: 95, to: png)
        #expect(imageProperties(jpeg)[kCGImagePropertyDepth] as? Int == 8)
        #expect((imageProperties(jpeg)[kCGImagePropertyProfileName] as? String)?.contains("sRGB") == true)
        #expect(imageProperties(heic)[kCGImagePropertyDepth] as? Int == 10)
        #expect((imageProperties(heic)[kCGImagePropertyProfileName] as? String)?.contains("HLG") == true)
        #expect(imageProperties(heic)[kCGImagePropertyPixelWidth] as? Int == 3840)
        #expect(imageProperties(png)[kCGImagePropertyDepth] as? Int == 16)
        #expect(readFrameNumber(imageAt: jpeg) == 10)
    }

    @Test func appliesDisplayRotation() throws {
        let (source, _, frame) = try decodeFrame(Fixtures.rotated, 5)
        let url = makeTemporaryDirectory().appendingPathComponent("r.jpg")
        try FrameImageRenderer().write(frame, rotationClockwise: source.rotationClockwise, format: .jpeg, quality: 90, to: url)
        #expect(imageProperties(url)[kCGImagePropertyPixelWidth] as? Int == 360)
        #expect(imageProperties(url)[kCGImagePropertyPixelHeight] as? Int == 640)
    }

    @Test func fallsBackWhenDirectoryIsNotWritable() async throws {
        let (source, _, frame) = try decodeFrame(Fixtures.h264, 0)
        let root = makeTemporaryDirectory()
        var config = Config()
        config.frameDirectory = "/System/FrameScrubCannotWriteHere"
        let exporter = FrameExporter(videoURL: source.url, rotationClockwise: 0,
                                     settings: ExportSettings(config: config, fallbackRoot: root))
        let saved = try await save(exporter, frame, seconds: 0)
        #expect(saved.usedFallbackDirectory)
        #expect(saved.url.deletingLastPathComponent().path == root.appendingPathComponent("h264_cfr_gop250").path)
    }

    @Test func exportsRange() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let root = makeTemporaryDirectory()
        let count = try await withCheckedThrowingContinuation { continuation in
            _ = exporter(for: source.url, root: root).exportRange(100...129, index: index, progress: { _, _ in }) {
                continuation.resume(with: $0.map(\.written))
            }
        }
        #expect(count == 30)
        let files = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("h264_cfr_gop250"), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count == 30)
        for (offset, file) in files.enumerated() {
            #expect(file.lastPathComponent.hasPrefix(String(format: "h264_cfr_gop250_f%06d_", 100 + offset)))
            #expect(readFrameNumber(imageAt: file) == 100 + offset)
        }
    }

    @Test func exportsOnlySelectedFrames() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let root = makeTemporaryDirectory()
        let seen = ProgressBox()
        let count = try await withCheckedThrowingContinuation { continuation in
            _ = exporter(for: source.url, root: root).exportRange(100...129, selection: .every(10), index: index,
                                                                   progress: { seen.record($0, of: $1) }) {
                continuation.resume(with: $0.map(\.written))
            }
        }
        #expect(count == 3)
        #expect(seen.maxWritten == 3 && seen.total == 3)   // progress may arrive out of order
        let files = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("h264_cfr_gop250"), includingPropertiesForKeys: nil)
            .compactMap { readFrameNumber(imageAt: $0) }.sorted()
        #expect(files == [100, 110, 120])
    }

    /// With the approximate (constant-rate) index of a VFR file, frame numbers are estimates but
    /// the time in the file name must still be the frame's real presentation time.
    @Test func vfrExportNamesUseFramePTSWithApproximateIndex() async throws {
        let source = try MediaSource(url: Fixtures.url(Fixtures.vfr))
        let index = source.approximateIndex()
        #expect(!index.isExact)
        let root = makeTemporaryDirectory()
        let count = try await withCheckedThrowingContinuation { continuation in
            _ = exporter(for: source.url, root: root).exportRange(70...79, index: index, progress: { _, _ in }) {
                continuation.resume(with: $0.map(\.written))
            }
        }
        #expect(count > 0)
        let files = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("h264_vfr"), includingPropertiesForKeys: nil)
        #expect(files.count == count)
        for file in files {
            let real = try #require(readFrameNumber(imageAt: file))
            let ticks = real < 60 ? real * 2 : 60 + real   // 1/60 s ticks, see make-fixtures.sh
            let expected = FrameNaming.timecode(Double(ticks) / 60, separator: "-")
            #expect(file.deletingPathExtension().lastPathComponent.hasSuffix("_" + expected),
                    "\(file.lastPathComponent) shows frame \(real)")
        }
    }

    @Test func cancellingRangeExportStopsEarly() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let root = makeTemporaryDirectory()
        let box = FlagBox()
        let count = try await withCheckedThrowingContinuation { continuation in
            box.flag = exporter(for: source.url, root: root).exportRange(0...599, index: index, progress: { written, _ in
                if written >= 10 { box.flag?.cancel() }
            }) { continuation.resume(with: $0.map(\.written)) }
        }
        #expect(count >= 10 && count < 600)
        let files = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("h264_cfr_gop250"), includingPropertiesForKeys: nil)
        #expect(files.count == count)
        for file in files { #expect(readFrameNumber(imageAt: file) != nil) }
    }

    @Test func sdrSourceKeeps10BitHEICAnd16BitPNGInSourceColourSpace() throws {
        let (_, _, frame) = try decodeFrame(Fixtures.h264, 3)
        let root = makeTemporaryDirectory()
        let renderer = FrameImageRenderer()
        let heic = root.appendingPathComponent("s.heic")
        let png = root.appendingPathComponent("s.png")
        try renderer.write(frame, rotationClockwise: 0, format: .heic, quality: 90, to: heic)
        try renderer.write(frame, rotationClockwise: 0, format: .png, quality: 90, to: png)
        #expect(imageProperties(heic)[kCGImagePropertyDepth] as? Int == 10)
        #expect(imageProperties(png)[kCGImagePropertyDepth] as? Int == 16)
        let name = try #require(imageProperties(png)[kCGImagePropertyProfileName] as? String)
        #expect(name == "HDTV")
    }

    @Test func jpegOfHLGFrameIsToneMappedNotClipped() throws {
        let (_, _, frame) = try decodeFrame(Fixtures.hevc10, 10)
        let root = makeTemporaryDirectory()
        let mapped = root.appendingPathComponent("mapped.jpg")
        let clipped = root.appendingPathComponent("clipped.jpg")
        try FrameImageRenderer().write(frame, rotationClockwise: 0, format: .jpeg, quality: 95, to: mapped)
        let raw = FrameImageRenderer.image(for: frame, rotationClockwise: 0, toneMapToSDR: false)
        try CIContext().writeJPEGRepresentation(of: raw, to: clipped, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
        let a = try #require(rgbaPixels(imageAt: mapped)), b = try #require(rgbaPixels(imageAt: clipped))
        #expect(a.count == b.count)
        var differing = 0, maxDiff = 0
        for pixel in 0..<min(a.count, b.count) / 4 {
            let d = (0..<3).map { abs(Int(a[pixel * 4 + $0]) - Int(b[pixel * 4 + $0])) }.max()!
            maxDiff = max(maxDiff, d)
            if d > 16 { differing += 1 }
        }
        // Tone mapping changes the bright/saturated areas; plain conversion leaves them clearly different.
        #expect(differing > 1000 && maxDiff > 40)
    }

    @Test func saveScaleTwoWritesADoubleSizeFileWithSuffix() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.h264, 42)
        let root = makeTemporaryDirectory()
        let saved = try await save(exporter(for: source.url, root: root) { $0.saveScale = 2 }, frame,
                                   seconds: index.seconds(forFrame: 42))
        #expect(saved.url.lastPathComponent == "h264_cfr_gop250_f000042_00-00-01.400_x2.jpg")
        let properties = imageProperties(saved.url)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 3840)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2160)
        #expect(readFrameNumber(imageAt: saved.url, scale: 2) == 42)
    }

    @Test func saveScaleFourWritesAQuadrupleSizeFile() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.withAudio, 3)
        let root = makeTemporaryDirectory()
        let saved = try await save(exporter(for: source.url, root: root) { $0.saveScale = 4; $0.saveUpscaler = .lanczos },
                                   frame, seconds: index.seconds(forFrame: 3))
        #expect(saved.url.lastPathComponent.hasSuffix("_x4.jpg"))
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelWidth] as? Int == 2560)
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelHeight] as? Int == 1440)
        #expect(readFrameNumber(imageAt: saved.url, scale: 4) == 3)
    }

    @Test func upscaledHDRStaysSixteenBitInPNG() throws {
        let (_, _, frame) = try decodeFrame(Fixtures.hevc10, 10)
        let url = makeTemporaryDirectory().appendingPathComponent("a_x2.png")
        try FrameImageRenderer().write(frame, rotationClockwise: 0, format: .png, quality: 95, scale: 2,
                                       upscaler: .lanczos, to: url)
        #expect(imageProperties(url)[kCGImagePropertyDepth] as? Int == 16)
        #expect(imageProperties(url)[kCGImagePropertyPixelWidth] as? Int == 7680)
    }

    @Test func rotationHappensBeforeUpscaling() throws {
        let (source, _, frame) = try decodeFrame(Fixtures.rotated, 5)
        let url = makeTemporaryDirectory().appendingPathComponent("r.jpg")
        try FrameImageRenderer().write(frame, rotationClockwise: source.rotationClockwise, format: .jpeg, quality: 90,
                                       scale: 2, upscaler: .lanczos, to: url)
        #expect(imageProperties(url)[kCGImagePropertyPixelWidth] as? Int == 720)
        #expect(imageProperties(url)[kCGImagePropertyPixelHeight] as? Int == 1280)
    }

    @Test func rangeExportUsesExportScale() async throws {
        let (source, index, _) = try decodeFrame(Fixtures.h264, 10)
        let root = makeTemporaryDirectory()
        let ranged = exporter(for: source.url, root: root) { $0.exportScale = 2; $0.saveScale = 1 }
        let count = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            _ = ranged.exportRange(10...12, index: index, progress: { _, _ in }) { continuation.resume(with: $0.map(\.written)) }
        }
        #expect(count == 3)
        let directory = root.appendingPathComponent("h264_cfr_gop250")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.hasSuffix("_x2.jpg") })
        let first = directory.appendingPathComponent(files[0])
        #expect(imageProperties(first)[kCGImagePropertyPixelWidth] as? Int == 3840)
        #expect(readFrameNumber(imageAt: first, scale: 2) == 10)
    }

    @Test func mlSaveFallsBackToLanczosAndReportsWhy() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.hevc10, 10)    // 3840 px: always too large
        let root = makeTemporaryDirectory()
        let saved = try await save(exporter(for: source.url, root: root) { $0.saveScale = 2; $0.saveUpscaler = .ml },
                                   frame, seconds: index.seconds(forFrame: 10))
        #expect(saved.fallbackReason == "source larger than 1920 px")
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelWidth] as? Int == 7680)
        #expect(saved.url.lastPathComponent.hasSuffix("_x2.jpg"))
    }

    @Test func plainSaveReportsNoFallback() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.h264, 4)
        let saved = try await save(exporter(for: source.url, root: makeTemporaryDirectory()), frame,
                                   seconds: index.seconds(forFrame: 4))
        #expect(saved.fallbackReason == nil)
    }

    @Test func fitScreenSavesAtTheScreenSizeWithASizeSuffix() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.h264, 42)
        let root = makeTemporaryDirectory()
        let saver = exporter(for: source.url, root: root, screen: CGSize(width: 3000, height: 2000)) {
            $0.saveScale = .fitScreen
            $0.saveUpscaler = .lanczos
        }
        let saved = try await save(saver, frame, seconds: index.seconds(forFrame: 42))
        #expect(saved.url.lastPathComponent.hasSuffix("_3000x1688.jpg"))    // 1920x1080 fitted into 3000x2000
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelWidth] as? Int == 3000)
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelHeight] as? Int == 1688)
    }

    @Test func aFixedWidthSmallerThanTheFrameDownscalesIt() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.h264, 42)
        let saved = try await save(exporter(for: source.url, root: makeTemporaryDirectory()) { $0.saveScale = .width(960) },
                                   frame, seconds: index.seconds(forFrame: 42))
        #expect(saved.url.lastPathComponent.hasSuffix("_960x540.jpg"))
        #expect(saved.fallbackReason == nil)
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelWidth] as? Int == 960)
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelHeight] as? Int == 540)
        #expect(readFrameNumber(imageAt: saved.url, scale: 0.5) == 42)
    }

    @Test func aFixedHeightFollowsRotation() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.rotated, 5)    // upright 360x640
        let rotated = FrameExporter(videoURL: source.url, rotationClockwise: source.rotationClockwise,
                                    settings: {
            var config = Config()
            config.frameDirectory = makeTemporaryDirectory().path + "/%{video-name}"
            config.saveScale = .height(1280)
            config.saveUpscaler = .lanczos
            return ExportSettings(config: config)
        }())
        let saved = try await save(rotated, frame, seconds: index.seconds(forFrame: 5))
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelWidth] as? Int == 720)
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelHeight] as? Int == 1280)
    }

    @Test func fitScreenWithoutAKnownScreenSavesAtSourceSize() async throws {
        let (source, index, frame) = try decodeFrame(Fixtures.h264, 7)
        let saved = try await save(exporter(for: source.url, root: makeTemporaryDirectory()) { $0.saveScale = .fitScreen },
                                   frame, seconds: index.seconds(forFrame: 7))
        #expect(imageProperties(saved.url)[kCGImagePropertyPixelWidth] as? Int == 1920)
        #expect(!saved.url.lastPathComponent.contains("x1080"))
    }

    @Test func rangeExportUsesAFixedWidth() async throws {
        let (source, index, _) = try decodeFrame(Fixtures.h264, 10)
        let root = makeTemporaryDirectory()
        let ranged = exporter(for: source.url, root: root) { $0.exportScale = .width(640) }
        let count = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            _ = ranged.exportRange(10...11, index: index, progress: { _, _ in }) { continuation.resume(with: $0.map(\.written)) }
        }
        #expect(count == 2)
        let directory = root.appendingPathComponent("h264_cfr_gop250")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files.allSatisfy { $0.hasSuffix("_640x360.jpg") })
        #expect(imageProperties(directory.appendingPathComponent(files[0]))[kCGImagePropertyPixelWidth] as? Int == 640)
    }
    @Test func sharpExportWritesAtMostOneFramePerWindow() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let root = makeTemporaryDirectory()
        let seen = ProgressBox()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExportResult, Error>) in
            _ = exporter(for: source.url, root: root) { $0.exportSharp = true; $0.exportSkipBlurry = true }
                .exportRange(100...129, selection: .every(10), index: index, progress: { seen.record($0, of: $1) }) {
                    continuation.resume(with: $0)
                }
        }
        #expect(result.written + result.blurry == 3 && result.duplicates == 0)
        #expect(seen.maxWritten == 3 && seen.total == 3)
        let frames = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("h264_cfr_gop250"), includingPropertiesForKeys: nil)
            .compactMap { readFrameNumber(imageAt: $0) }.sorted()
        #expect(frames.count == result.written)
        #expect(frames.allSatisfy { (100...129).contains($0) })
        #expect(Set(frames.map { ($0 - 100) / 10 }).count == frames.count)   // one file per window at most
    }

    /// Candidates wait for later windows; holding many must not starve the hardware decoder.
    @Test(.timeLimit(.minutes(2))) func sharpExportHoldsManyHDRCandidates() async throws {
        let (source, index) = try openIndexed(Fixtures.hevc10)
        let root = makeTemporaryDirectory()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExportResult, Error>) in
            _ = exporter(for: source.url, root: root) {
                $0.exportSharp = true
                $0.exportSkipBlurry = true
                $0.exportSharpNeighbours = 31
                $0.exportScale = .width(320)
            }
            .exportRange(0...119, selection: .every(2), index: index, progress: { _, _ in }) { continuation.resume(with: $0) }
        }
        #expect(result.written + result.blurry == 60)
    }

    /// Without `export-sharp` the blurry check sees only the selected frames.
    @Test func blurrySkipWithoutSharpestJudgesTheSelectedFrames() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let root = makeTemporaryDirectory()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExportResult, Error>) in
            _ = exporter(for: source.url, root: root) { $0.exportSkipBlurry = true }
                .exportRange(100...129, selection: .every(10), index: index, progress: { _, _ in }) { continuation.resume(with: $0) }
        }
        #expect(result.written + result.blurry == 3)
        let frames = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("h264_cfr_gop250"), includingPropertiesForKeys: nil)
            .compactMap { readFrameNumber(imageAt: $0) }
        #expect(Set(frames).isSubset(of: [100, 110, 120]))
    }

    /// The fixture's frames differ only in a small frame counter: at 50 % every frame repeats the first one.
    @Test func duplicateSkipKeepsOneFrameOfAStillPicture() async throws {
        let (source, index) = try openIndexed(Fixtures.h264)
        let root = makeTemporaryDirectory()
        let seen = ProgressBox()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExportResult, Error>) in
            _ = exporter(for: source.url, root: root) { $0.exportSkipDuplicates = true; $0.exportDuplicateChange = 50 }
                .exportRange(100...129, selection: .every(10), index: index, progress: { seen.record($0, of: $1) }) {
                    continuation.resume(with: $0)
                }
        }
        #expect(result == ExportResult(written: 1, duplicates: 2))
        #expect(seen.maxWritten == 3 && seen.total == 3)
        let frames = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("h264_cfr_gop250"), includingPropertiesForKeys: nil)
            .compactMap { readFrameNumber(imageAt: $0) }
        #expect(frames == [100])
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var maxWritten = 0
    private(set) var total = 0
    func record(_ written: Int, of total: Int) {
        lock.withLock { maxWritten = max(maxWritten, written); self.total = total }
    }
}
