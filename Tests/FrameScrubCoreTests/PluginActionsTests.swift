import Testing
@testable import FrameScrubCore

@Suite struct PluginActionsTests {
    private func chord(_ s: String) -> KeyChord { KeyChord.parse(s)! }

    private func failure(_ list: [[String: Any]]) -> String? {
        if case let .failure(f) = PluginActions.parse(list) { return f.reason }
        return nil
    }

    @Test func parsesNameLabelAndOptionalKey() throws {
        let actions = try PluginActions.parse([
            ["name": "mark", "label": "Mark here", "key": "Alt+1"],
            ["name": "next_2", "label": "Next"],
        ]).get()
        #expect(actions == [PluginAction(name: "mark", label: "Mark here", key: chord("Alt+1")),
                            PluginAction(name: "next_2", label: "Next", key: nil)])
        #expect(try PluginActions.parse([]).get() == [])
    }

    @Test func refusesTheWholeListWithTheIndexOfTheBadEntry() {
        let ok: [String: Any] = ["name": "mark", "label": "Mark"]
        let name = "must be 1-32 of a-z 0-9 - _"
        #expect(failure([ok, ["name": "", "label": "x"]]) == "actions[1].name \(name)")
        #expect(failure([["name": "A", "label": "x"]]) == "actions[0].name \(name)")
        #expect(failure([["name": String(repeating: "a", count: 33), "label": "x"]]) == "actions[0].name \(name)")
        #expect(failure([["name": "a b", "label": "x"]]) == "actions[0].name \(name)")
        #expect(failure([["label": "x"]]) == "actions[0].name \(name)")
        #expect(failure([["name": 3, "label": "x"]]) == "actions[0].name \(name)")
        #expect(failure([["name": "mark", "label": ""]]) == "actions[0].label must be 1-60 characters")
        #expect(failure([["name": "mark", "label": String(repeating: "é", count: 61)]])
                == "actions[0].label must be 1-60 characters")
        #expect(failure([["name": "mark"]]) == "actions[0].label must be 1-60 characters")
        #expect(failure([ok, ["name": "next", "label": "Next", "key": "Alt+"]]) == "actions[1].key is not a key")
        #expect(failure([["name": "next", "label": "Next", "key": 1]]) == "actions[0].key is not a key")
        #expect(failure([["name": "next", "label": "Next", "key": "a b"]]) == "actions[0].key is not a key")
        #expect(failure([ok, ["name": "mark", "label": "Again"]]) == "duplicate name mark")
    }

    @Test func acceptsTheLimits() throws {
        let name = String(repeating: "z", count: 32), label = String(repeating: "é", count: 60)
        let actions = try PluginActions.parse([["name": name, "label": label], ["name": "a-0_b", "label": "x"]]).get()
        #expect(actions.map(\.name) == [name, "a-0_b"])
    }

    @Test func bindsAFreePageKey() {
        let base = InputMap(layout: .classic)
        let (map, bound, refused) = base.merging([PluginAction(name: "mark", label: "Mark", key: chord("Alt+1"))])
        #expect(map.command(for: chord("Alt+1")) == .pluginAction("mark"))
        #expect(bound == [PluginBinding(name: "mark", key: chord("Alt+1"), reason: nil)])
        #expect(refused.isEmpty)
    }

    @Test func refusesAKeyTheLayoutOrInputConfAlreadyBinds() {
        var base = InputMap(layout: .classic)
        base.apply("Alt+1 ignore\nAlt+2 cycle pause")
        let (map, bound, refused) = base.merging([
            PluginAction(name: "mark", label: "Mark", key: chord("Alt+1")),
            PluginAction(name: "next", label: "Next", key: chord("Alt+2")),
            PluginAction(name: "play", label: "Play", key: chord("SPACE")),
        ])
        #expect(bound.isEmpty)
        #expect(refused == [PluginBinding(name: "mark", key: chord("Alt+1"), reason: "key taken"),
                            PluginBinding(name: "next", key: chord("Alt+2"), reason: "key taken"),
                            PluginBinding(name: "play", key: chord("SPACE"), reason: "key taken")])
        #expect(map.bindings == base.bindings)
    }

    @Test func refusesTheCommandChordsOfMenuItems() {
        let base = InputMap(layout: .classic)
        let (map, bound, refused) = base.merging([
            PluginAction(name: "mark", label: "Mark", key: chord("Meta+w")),
            PluginAction(name: "next", label: "Next", key: chord("Meta+1")),
            PluginAction(name: "shut", label: "Shut", key: chord("Meta+Shift+o")),
            PluginAction(name: "free", label: "Free", key: chord("Meta+9")),
        ])
        #expect(refused.map(\.name) == ["mark", "next", "shut"])
        #expect(refused.allSatisfy { $0.reason == "key taken" })
        #expect(bound.map(\.name) == ["free"])
        #expect(map.command(for: chord("Meta+o")) != .pluginAction("shut"))
        #expect(map.command(for: chord("Meta+9")) == .pluginAction("free"))
    }

    @Test func aSecondActionOnTheSameKeyIsRefused() {
        let (map, bound, refused) = InputMap().merging([
            PluginAction(name: "mark", label: "Mark", key: chord("Alt+1")),
            PluginAction(name: "next", label: "Next", key: chord("Alt+1")),
        ])
        #expect(map.command(for: chord("Alt+1")) == .pluginAction("mark"))
        #expect(bound.map(\.name) == ["mark"])
        #expect(refused == [PluginBinding(name: "next", key: chord("Alt+1"), reason: "key taken")])
    }

    @Test func theUsersOwnBindingWins() {
        var base = InputMap(layout: .classic)
        base.apply("Alt+9 plugin-action mark")
        let (map, bound, refused) = base.merging([PluginAction(name: "mark", label: "Mark", key: chord("Alt+1"))])
        #expect(map.command(for: chord("Alt+9")) == .pluginAction("mark"))
        #expect(map.command(for: chord("Alt+1")) == nil)
        #expect(bound.isEmpty)
        #expect(refused == [PluginBinding(name: "mark", key: chord("Alt+1"), reason: "user binding")])
    }

    @Test func anActionWithoutAKeyIsNeitherBoundNorRefused() {
        let base = InputMap()
        let (map, bound, refused) = base.merging([PluginAction(name: "mark", label: "Mark", key: nil)])
        #expect(bound.isEmpty && refused.isEmpty)
        #expect(map.bindings == base.bindings)
    }

    @Test func mergingNothingLeavesTheMapAsItIs() {
        let base = InputMap(layout: .leftHand)
        let (map, bound, refused) = base.merging([])
        #expect(map.bindings == base.bindings && bound.isEmpty && refused.isEmpty)
    }

    @Test func aPointerOrWheelNameIsNotAKey() {
        let names = ["MBTN_LEFT", "MBTN_RIGHT", "WHEEL_UP", "TRACKPAD_LEFT", "PINCH_IN", "MX_PANEL", "MBTN_BACK+WHEEL_UP"]
        let actions = names.enumerated().map { PluginAction(name: "a\($0.offset)", label: "A", key: chord($0.element)) }
        let (map, bound, refused) = InputMap().merging(actions)
        #expect(bound.isEmpty)
        #expect(refused.map(\.reason) == Array(repeating: "not a key", count: names.count))
        #expect(map.bindings == InputMap().bindings)
    }

    @Test func aUserBindingRefusalCarriesThePagesKeyIntoTheReply() {
        var base = InputMap(layout: .classic)
        base.apply("Alt+9 plugin-action mark")
        let outcome = base.merging([PluginAction(name: "mark", label: "Mark", key: chord("Alt+1"))])
        #expect(PluginActionsReply(bound: outcome.bound, refused: outcome.refused).json
            == #"{"bound":[],"refused":[{"key":"Alt+1","name":"mark","reason":"user binding"}]}"#)
    }

    @Test func thePolicyDispatchesOnlyADeclaredNameOfAShownPage() {
        let declared = [PluginAction(name: "mark", label: "Mark", key: nil)]
        // while the page is in a slot, shown or hidden (an overlay slot hides while the video plays)
        #expect(PluginActionPolicy.shouldDispatch("mark", declared: declared, inSlot: true))
        #expect(!PluginActionPolicy.shouldDispatch("mark", declared: declared, inSlot: false))
        #expect(!PluginActionPolicy.shouldDispatch("next", declared: declared, inSlot: true))
        #expect(!PluginActionPolicy.shouldDispatch("mark", declared: [], inSlot: true))
    }

    @Test func theDeclaredKeysAreBoundWhileThePageIsInASlot() {
        let declared = [PluginAction(name: "mark", label: "Mark", key: chord("Alt+1"))]
        #expect(PluginActionPolicy.bindable(declared, inSlot: true) == declared)
        #expect(PluginActionPolicy.bindable(declared, inSlot: false).isEmpty)
    }
}
