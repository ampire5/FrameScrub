import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PluginOriginTests {
    private func origin(_ string: String) -> PluginOrigin? { PluginOrigin(url: URL(string: string)!) }

    @Test func schemeHostAndPort() {
        let o = origin("http://Host.local:8000/p/index.html?q=1")
        #expect(o?.scheme == "http")
        #expect(o?.host == "host.local")
        #expect(o?.port == 8000)
        #expect(o?.description == "http://host.local:8000")
    }

    @Test func theSchemesOwnPortIsLeftOut() {
        #expect(origin("http://host:80/") == origin("http://host/"))
        #expect(origin("https://host:443/") == origin("https://host/"))
        #expect(origin("http://host/")?.description == "http://host")
        #expect(origin("http://host:443/") != origin("https://host/"))
    }

    @Test func pathsDoNotMatterButPortsDo() {
        #expect(origin("http://host:8000/a") == origin("http://host:8000/b/c"))
        #expect(origin("http://host:8000/") != origin("http://host:8001/"))
        #expect(origin("http://host:8000/") != origin("https://host:8000/"))
    }

    @Test func localPagesShareOneOrigin() {
        #expect(origin("file:///Users/me/a/index.html") == origin("file:///tmp/b.html"))
        #expect(origin("file:///Users/me/a/index.html")?.description == "file://")
    }

    @Test func otherSchemesHaveNoOrigin() {
        #expect(origin("javascript:1") == nil)
        #expect(origin("data:text/html,x") == nil)
        #expect(origin("framescrub://open?path=/a") == nil)
    }

    @Test func fromTheBrowsersParts() {
        #expect(PluginOrigin(scheme: "HTTP", host: "Host", port: 0) == origin("http://host/"))
        #expect(PluginOrigin(scheme: "http", host: "host", port: 8000) == origin("http://host:8000/"))
        #expect(PluginOrigin(scheme: "file", host: "", port: 0) == origin("file:///x"))
        #expect(PluginOrigin(scheme: "about", host: "", port: 0) == nil)
    }

    @Test func roundTripsThroughItsText() {
        for text in ["http://host:8000", "https://host", "file://"] {
            #expect(PluginOrigin(string: text)?.description == text)
        }
        #expect(PluginOrigin(string: "http://host:8000/path") == nil)
        #expect(PluginOrigin(string: "nonsense") == nil)
    }
}

@Suite struct PluginPolicyTests {
    private let page = PluginOrigin(url: URL(string: "http://host:8000/p/")!)!
    private let other = PluginOrigin(url: URL(string: "http://other/")!)!
    private let video = URL(fileURLWithPath: "/Volumes/V/a.mp4")

    @Test func trustsThePagesOrigin() {
        var policy = PluginPolicy()
        #expect(!policy.isTrusted(page))
        let trusted = policy.trust(URL(string: "http://host:8000/p/index.html")!)
        #expect(trusted)
        #expect(policy.isTrusted(page))
        #expect(policy.isTrusted(URL(string: "http://host:8000/other")!))
        #expect(!policy.isTrusted(other))
        let notAPage = policy.trust(URL(string: "framescrub://open?path=/a")!)
        #expect(!notAPage)
    }

    @Test func openingNeedsTrustThenMediaThenConsent() {
        var policy = PluginPolicy()
        #expect(policy.decision(forOpening: video, from: page) == .untrusted)
        policy.trust(URL(string: "http://host:8000/")!)
        #expect(policy.decision(forOpening: video, from: page) == .needsConsent)
        #expect(policy.decision(forOpening: URL(fileURLWithPath: "/etc/passwd"), from: page) == .notMedia)
        #expect(policy.decision(forOpening: URL(fileURLWithPath: "/a/b.txt"), from: page) == .notMedia)
        policy.allowOpening(from: page)
        #expect(policy.decision(forOpening: video, from: page) == .allowed)
        #expect(policy.decision(forOpening: URL(fileURLWithPath: "/a/B.MKV"), from: page) == .allowed)
        #expect(policy.decision(forOpening: URL(fileURLWithPath: "/etc/passwd"), from: page) == .notMedia)
    }

    @Test func consentIsPerOrigin() {
        var policy = PluginPolicy(trusted: [page, other])
        policy.allowOpening(from: page)
        #expect(policy.decision(forOpening: video, from: page) == .allowed)
        #expect(policy.decision(forOpening: video, from: other) == .needsConsent)
    }

    @Test func rememberedOriginsRoundTrip() {
        var policy = PluginPolicy(trusted: [page, other])
        policy.allowOpening(from: other)
        policy.allowOpening(from: page)
        #expect(policy.openAllowedStrings == ["http://host:8000", "http://other"])
        let restored = PluginPolicy(trusted: [page], openAllowedStrings: policy.openAllowedStrings + ["junk"])
        #expect(restored.openAllowed == policy.openAllowed)
        #expect(restored.decision(forOpening: video, from: page) == .allowed)
    }

    @Test func mediaFilesAreTheOnesThePlaylistLists() {
        #expect(PluginPolicy.isMediaFile(URL(fileURLWithPath: "/a.mp4")))
        #expect(PluginPolicy.isMediaFile(URL(fileURLWithPath: "/a.MOV")))
        #expect(!PluginPolicy.isMediaFile(URL(fileURLWithPath: "/a.jpg")))
        #expect(!PluginPolicy.isMediaFile(URL(fileURLWithPath: "/a")))
        #expect(!PluginPolicy.isMediaFile(URL(string: "http://host/a.mp4")!))
    }

    @Test func theQuestionNamesTheOrigin() {
        #expect(PluginPolicy.consentQuestion(for: page) == "Allow http://host:8000 to open files in FrameScrub?")
    }
}
