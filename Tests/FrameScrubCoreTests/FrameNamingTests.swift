import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct FrameNamingTests {
    let naming = FrameNaming(directoryTemplate: Config().frameDirectory, fileTemplate: Config().frameTemplate)
    let video = URL(fileURLWithPath: "/videos/clip.mov")

    @Test func expandsDefaultTemplates() {
        #expect(naming.directory(forVideo: video).path == "/videos/clip")
        #expect(naming.fileName(forVideo: video, frame: 42, seconds: 1.4, format: .jpeg) == "clip_f000042_00-00-01.400.jpg")
        #expect(naming.fileName(forVideo: video, frame: 1_234_567, seconds: 0, format: .png) == "clip_f1234567_00-00-00.000.png")
    }

    @Test func formatsTimecodes() {
        #expect(FrameNaming.timecode(3723.4567) == "01:02:03.457")
        #expect(FrameNaming.timecode(-1) == "00:00:00.000")
        #expect(FrameNaming.timecode(59.9996, separator: "-") == "00-01-00.000")
    }

    @Test func keepsUnknownPlaceholdersAndExpandsTilde() {
        let custom = FrameNaming(directoryTemplate: "~/Frames/%{video-name}", fileTemplate: "%{nope}_%{frame}")
        #expect(custom.directory(forVideo: video).path == NSHomeDirectory() + "/Frames/clip")
        #expect(custom.fileName(forVideo: video, frame: 7, seconds: 0, format: .tiff) == "%{nope}_7.tiff")
    }

    @Test func clipNames() {
        let video = URL(fileURLWithPath: "/v/Video.mp4")
        func name(_ template: String) -> String {
            FrameNaming.clipFileName(forVideo: video, startSeconds: 753.1, endSeconds: 785.0, frame: 42, seconds: 1.4,
                                     template: template, fileExtension: "mp4")
        }
        #expect(name(Config().clipTemplate) == "Video_00-12-33.100_00-13-05.000.mp4")
        #expect(name("%{start:hh.mm.ss}-%{end:hh.mm.ss}") == "00.12.33.100-00.13.05.000.mp4")
        #expect(name("%{video-name}_%{frame:04}_%{time}") == "Video_0042_00-00-01.400.mp4")
    }

    @Test func fallbackDirectoryUsesVideoName() {
        let root = URL(fileURLWithPath: "/tmp/root")
        #expect(FrameNaming.fallbackDirectory(forVideo: video, root: root).path == "/tmp/root/clip")
    }

    @Test func scaleSuffixGoesBeforeTheExtension() {
        let naming = FrameNaming(directoryTemplate: "/tmp", fileTemplate: "%{video-name}_f%{frame:06}")
        let video = URL(fileURLWithPath: "/v/clip.mp4")
        #expect(naming.fileName(forVideo: video, frame: 7, seconds: 0, format: .png) == "clip_f000007.png")
        #expect(naming.fileName(forVideo: video, frame: 7, seconds: 0, format: .png, scale: 1) == "clip_f000007.png")
        #expect(naming.fileName(forVideo: video, frame: 7, seconds: 0, format: .jpeg, scale: 2) == "clip_f000007_x2.jpg")
        #expect(naming.fileName(forVideo: video, frame: 7, seconds: 0, format: .heic, scale: 4) == "clip_f000007_x4.heic")
    }
}
