import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct BridgeScriptTests {
    private let origin = PluginOrigin(url: URL(string: "https://notes.example")!)!

    @Test func versionTwoWithTheNewVerbs() {
        let script = PluginBridgeScript.source(trusted: [origin], stash: nil)
        #expect(script.contains("version: 2,"))
        #expect(script.contains("hide() { this.send(\"hide\"); }"))
        #expect(script.contains("\"setPlaylist\""))
        #expect(script.contains("enqueue(items) { this.send(\"enqueue\", {items}); }"))
    }

    @Test func onlyTheTrustedOriginsGetIt() {
        let script = PluginBridgeScript.source(trusted: [origin], stash: nil)
        #expect(script.hasPrefix("if ([\"https://notes.example\"].includes(location.protocol + \"//\" + location.host)) {"))
    }

    @Test func noStashIsNull() {
        #expect(PluginBridgeScript.source(trusted: [origin], stash: nil).contains("stash: null,"))
    }

    @Test func stashValuesAreJSONEscaped() {
        let stash = PluginBridgeScript.StashAccess(url: "http://nas.local:9999", apiKey: "k\"ey</script>")
        let script = PluginBridgeScript.source(trusted: [origin], stash: stash, stashOrigins: [origin])
        #expect(script.contains(#"{"apiKey":"k\"ey<\/script>","url":"http:\/\/nas.local:9999"}"#))
    }

    @Test func stashOnlyForTheConfiguredPlugins() {
        // A page a link brought is trusted with the bridge, not with the server's key.
        let stash = PluginBridgeScript.StashAccess(url: "http://nas.local:9999", apiKey: "key")
        let script = PluginBridgeScript.source(trusted: [origin], stash: stash, stashOrigins: [origin])
        #expect(script.contains(#"stash: (["https://notes.example"].includes(location.protocol + "//" + location.host) ? {"#))
        #expect(script.contains(#""} : null),"#))
        #expect(PluginBridgeScript.source(trusted: [origin], stash: stash, stashOrigins: []).contains("stash: null,"))
    }

    @Test func extraScriptGoesInsideTheGuard() {
        let script = PluginBridgeScript.source(trusted: [origin], stash: nil, extra: "/*keys*/")
        #expect(script.hasSuffix("/*keys*/\n}"))
    }

    @Test func panelEvent() {
        let info = PanelInfo(slot: .right, mode: .overlay, backdrop: .glass, shown: true, focused: false)
        #expect(PluginEvent.panel(info).name == "panel")
        #expect(PluginEvent.panel(info).detail == info.json)
    }
}
