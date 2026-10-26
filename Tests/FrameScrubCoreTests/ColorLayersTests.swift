import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ColorLayersTests {
    private func config(_ pairs: [String: String]) -> Config {
        Config().applying(pairs).0
    }

    private func effective(_ global: Config, _ chain: [[String: String]] = [], _ file: [String: String]? = nil) -> Config {
        ColorLayers.effective(global: global, folderChain: chain, file: file).config
    }

    // MARK: effective

    @Test func nothingStoredIsTheGlobalConfig() {
        let global = config(["auto-color": "yes", "vibrance": "0.3"])
        let result = ColorLayers.effective(global: global, folderChain: [[:], [:]], file: nil)
        #expect(result.config == global)
        #expect(result.origin == .default)
    }

    @Test func fileBeatsFolderBeatsAncestorBeatsGlobalKeyByKey() {
        let global = config(["auto-color-strength": "0.1", "vibrance": "0.1"])
        let chain = [["auto-color-strength": "0.2"], ["auto-color-strength": "0.3", "vibrance": "0.3", "vibrance-on": "yes"]]
        let config = effective(global, chain, ["auto-color-strength": "0.9"])
        #expect(config.autoColorStrength == 0.9)       // file
        #expect(config.vibrance == 0.3)                // nearest ancestor with the key; the folder has none
        #expect(config.vibranceOn)                     // ancestor
        #expect(!config.autoColor)                     // nobody has it
    }

    @Test func fileWithOnlyStrengthTakesAutoColorFromTheFolder() {
        let chain = [["auto-color": "yes", "auto-color-strength": "0.4"]]
        let config = effective(Config(), chain, ["auto-color-strength": "0.6"])
        #expect(config.autoColor)
        #expect(config.autoColorStrength == 0.6)
    }

    @Test func otherKeysStayGlobal() {
        let global = Config.parse("auto-color-threshold=9").0
        let config = effective(global, [["auto-color-threshold": "1", "frame-format": "png"]], ["auto-color-full": "3"])
        #expect(config.autoColorThreshold == 9)
        #expect(config.autoColorFull == global.autoColorFull)
        #expect(config.frameFormat == global.frameFormat)
    }

    @Test func originIsTheMostSpecificLayerAnyKeyCameFrom() {
        let global = Config()
        #expect(ColorLayers.effective(global: global, folderChain: [[:]], file: ["vibrance": "0.2"]).origin == .file)
        #expect(ColorLayers.effective(global: global, folderChain: [["vibrance": "0.2"]], file: [:]).origin == .folder)
        // an ancestor counts as the folder
        #expect(ColorLayers.effective(global: global, folderChain: [[:], ["vibrance": "0.2"]], file: nil).origin == .folder)
        // file wins even when a folder also has values
        #expect(ColorLayers.effective(global: global, folderChain: [["auto-color": "yes"]], file: ["vibrance": "0.2"]).origin == .file)
    }

    @Test func aBadStoredValueIsRejectedAndTheLowerLayerKept() {
        let global = config(["auto-color-strength": "0.4"])
        let result = ColorLayers.effective(global: global, folderChain: [[:]], file: ["auto-color-strength": "lots"])
        #expect(result.config.autoColorStrength == 0.4)
        #expect(result.origin == .default)
        // the folder's valid value shows through a bad file value
        let viaFolder = ColorLayers.effective(global: global, folderChain: [["auto-color-strength": "0.7"]], file: ["auto-color-strength": "2"])
        #expect(viaFolder.config.autoColorStrength == 0.7)
        #expect(viaFolder.origin == .folder)
    }

    // MARK: Config.applying

    @Test func applyingTakesOnlyTheColourKeysAndReportsTheRest() {
        let (config, rejected) = Config().applying(["auto-color": "yes", "vibrance": "7", "frame-format": "png", "nope": "1"])
        #expect(config.autoColor)
        #expect(config.vibrance == Config().vibrance)
        #expect(config.frameFormat == Config().frameFormat)
        #expect(rejected == ["frame-format=png", "nope=1", "vibrance=7"])
    }

    // MARK: keysToClear

    private func clears(_ set: ColorSet, on level: ColorLevel?, global: Config = Config(), _ chain: [[String: String]] = [[:]],
                        file: [String: String]?) -> (file: [String], folder: [String]) {
        ColorLayers.keysToClear(set: set, savedOn: level, global: global, folderChain: chain, file: file)
    }

    @Test func defaultEqualToTheFilesValueClearsIt() {
        // ⇧C with the file at 0.6 over the default 1: the effective strength 0.6 becomes the default, so the file's
        // own entry is redundant (the new default equals it)
        let result = clears(.autoColor, on: nil, file: ["auto-color-strength": "0.6"])
        #expect(result.file == ["auto-color-strength"])
        #expect(result.folder.isEmpty)
    }

    @Test func aDefaultSaveLeavesTheFolderAloneWhileOtherFilesNeedIt() {
        // file 0.6 over folder 0.8, default saved as 0.6: the file's entry is not redundant (the folder says 0.8) and the
        // folder's 0.8 is not redundant either (the default is 0.6): a sibling file keeps its 0.8
        let chain = [["auto-color-strength": "0.8"]]
        let result = clears(.autoColor, on: nil, chain, file: ["auto-color-strength": "0.6"])
        #expect(result.file.isEmpty)
        #expect(result.folder.isEmpty)
        let global = Config.parse("auto-color-strength=0.6").0      // as the save leaves it
        #expect(effective(global, chain, nil).autoColorStrength == 0.8)
    }

    @Test func theFileGoesWhenTheFolderSaysTheSameButTheFolderStaysOverItsAncestor() {
        // file 0.6 = folder 0.6 over ancestor 0.2, default 0.6: the file's entry is redundant, the folder's is not (ancestor 0.2)
        let result = clears(.autoColor, on: nil, [["auto-color-strength": "0.6"], ["auto-color-strength": "0.2"]],
                            file: ["auto-color-strength": "0.6"])
        #expect(result.file == ["auto-color-strength"])
        #expect(result.folder.isEmpty)
    }

    @Test func aFolderEntryGoesWhenTheDefaultEqualsItAndNothingElseShows() {
        // no file value: effective = folder's 0.8, default becomes 0.8 -> the folder's entry is redundant
        let result = clears(.autoColor, on: nil, [["auto-color-strength": "0.8"]], file: nil)
        #expect(result.folder == ["auto-color-strength"])
    }

    @Test func aFolderEntryStaysWhenAnAncestorWouldShowThroughIt() {
        // folder 0.8 over ancestor 0.2: dropping the folder entry would show 0.2, not 0.8
        let result = clears(.autoColor, on: nil, [["auto-color-strength": "0.8"], ["auto-color-strength": "0.2"]], file: nil)
        #expect(result.folder.isEmpty)
    }

    @Test func savingOnTheFolderClearsTheFilesValuesOfTheSetOnly() {
        let result = clears(.autoColor, on: .folder, [["auto-color-strength": "0.2"]],
                            file: ["auto-color": "yes", "auto-color-strength": "0.6", "vibrance": "0.9"])
        #expect(result.file == ["auto-color", "auto-color-strength"])
        #expect(result.folder.isEmpty)           // the folder is what was written, never "lower"
    }

    @Test func onlyKeysOfTheSetAreReturned() {
        let result = clears(.vibrance, on: nil, [["vibrance": "0.5", "auto-color": "yes"]],
                            file: ["vibrance-on": "yes", "auto-color": "yes", "vibrance": "0.5"])
        #expect(Set(result.file).isSubset(of: ColorSet.vibrance.keys))
        #expect(Set(result.folder).isSubset(of: ColorSet.vibrance.keys))
    }

    @Test func aBadStoredValueDoesNotMatter() {
        // the invalid file entry never drew, so removing it changes nothing
        #expect(clears(.autoColor, on: .folder, file: ["auto-color-strength": "lots"]).file == ["auto-color-strength"])
    }

    @Test func keySetsAreWhatTheSpecSays() {
        #expect(ColorSet.autoColor.keys == ["auto-color", "auto-color-strength"])
        #expect(ColorSet.vibrance.keys == ["vibrance-on", "vibrance"])
        #expect(ColorLayers.keys == ["auto-color", "auto-color-strength", "vibrance-on", "vibrance"])
    }

    // MARK: a save never changes the picture

    @Test func afterWritingAndClearingTheEffectiveConfigIsTheSame() {
        let values: [[String: String]?] = [
            nil, [:],
            ["auto-color-strength": "0.6"], ["auto-color": "yes"], ["auto-color": "no", "auto-color-strength": "0.2"],
            ["vibrance-on": "yes", "vibrance": "0.9"], ["vibrance": "0.4", "auto-color-strength": "x"],
        ]
        let globals = [Config(), config(["auto-color": "yes", "auto-color-strength": "0.6", "vibrance": "0.9", "vibrance-on": "yes"])]
        var checked = 0
        for global in globals {
            for file in values {
                for folder in values.compactMap({ $0 }) {
                    for ancestor in values.compactMap({ $0 }) {
                        for set in [ColorSet.autoColor, .vibrance] {
                            for level in [nil, ColorLevel.folder] {
                                let chain = [folder, ancestor]
                                let before = ColorLayers.effective(global: global, folderChain: chain, file: file).config
                                let clear = ColorLayers.keysToClear(set: set, savedOn: level, global: global, folderChain: chain, file: file)
                                // the write: the set's effective values onto the level, then the clears
                                let written = Dictionary(uniqueKeysWithValues: set.keys.map { ($0, before.text(forKey: $0)!) })
                                var newGlobal = global, newChain = chain, newFile = file
                                if level == nil { newGlobal = global.applying(written).0 } else { newChain[0].merge(written) { $1 } }
                                clear.file.forEach { newFile?[$0] = nil }
                                clear.folder.forEach { newChain[0][$0] = nil }
                                let after = ColorLayers.effective(global: newGlobal, folderChain: newChain, file: newFile).config
                                // a sibling file (no values of its own) draws as it would with the write alone: the clears change nobody
                                let sibling = ColorLayers.effective(global: newGlobal, folderChain: newChain, file: nil).config
                                var written2 = chain; if level != nil { written2[0].merge(written) { $1 } }
                                let siblingWriteOnly = ColorLayers.effective(global: newGlobal, folderChain: written2, file: nil).config
                                #expect(sibling == siblingWriteOnly, "sibling \(set) \(String(describing: level)) chain \(chain)")
                                #expect(after == before, "\(set) \(String(describing: level)) file \(String(describing: file)) chain \(chain)")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 500)
    }

    // MARK: The nearest level (the settings window's note)

    private let shoot = URL(fileURLWithPath: "/shoots/one", isDirectory: true)
    private let shoots = URL(fileURLWithPath: "/shoots", isDirectory: true)

    @Test func fileBeatsFolderBeatsAncestor() {
        let chain = [ColorLayerSnapshot.Folder(url: shoot, values: ["vibrance": "0.3"]),
                     ColorLayerSnapshot.Folder(url: shoots, values: ["vibrance": "0.2", "auto-color": "yes"])]
        let snapshot = ColorLayerSnapshot(file: ["vibrance": "0.4"], chain: chain)
        #expect(ColorLayers.nearest("vibrance", in: snapshot, global: Config())
                == ColorLayerHit(level: .file, value: "0.4", isNearestFolder: false))
        let noFile = ColorLayerSnapshot(file: nil, chain: chain)
        #expect(ColorLayers.nearest("vibrance", in: noFile, global: Config())
                == ColorLayerHit(level: .folder(shoot), value: "0.3", isNearestFolder: true))
        #expect(ColorLayers.nearest("auto-color", in: noFile, global: Config())
                == ColorLayerHit(level: .folder(shoots), value: "yes", isNearestFolder: false))
        #expect(ColorLayers.nearest("vibrance-on", in: snapshot, global: Config()) == nil)
    }

    @Test func aRefusedValueShowsTheNextLevel() {
        let snapshot = ColorLayerSnapshot(file: ["vibrance": "7"],
                                          chain: [ColorLayerSnapshot.Folder(url: shoot, values: ["vibrance": "0.3"])])
        #expect(ColorLayers.nearest("vibrance", in: snapshot, global: Config())?.level == .folder(shoot))
    }

    @Test func onlyColourKeysHaveLevels() {
        let snapshot = ColorLayerSnapshot(file: ["volume": "30"], chain: [])
        #expect(ColorLayers.nearest("volume", in: snapshot, global: Config()) == nil)
    }
}
