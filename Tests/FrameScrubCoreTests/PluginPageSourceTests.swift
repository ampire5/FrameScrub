import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct PluginPageSourceTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func webPagesFromAnySource() {
        #expect(PluginPageSource.settings.accepts(url("http://host:8000/p/")))
        #expect(PluginPageSource.link.accepts(url("http://host:8000/p/")))
        #expect(PluginPageSource.link.accepts(url("HTTPS://host/")))
    }

    @Test func aLocalPageOnlyFromTheSettings() {
        #expect(PluginPageSource.settings.accepts(url("file:///Users/me/plugin/index.html")))
        #expect(!PluginPageSource.link.accepts(url("file:///Users/me/plugin/index.html")))
    }

    @Test func otherSchemesFromNeither() {
        for text in ["javascript:alert(1)", "data:text/html,hi", "ftp://host/x", "about:blank", "x-apple.systempreferences:"] {
            #expect(!PluginPageSource.settings.accepts(url(text)), "\(text)")
            #expect(!PluginPageSource.link.accepts(url(text)), "\(text)")
        }
    }
}
