import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ColorMemoryTests {
    private let a = URL(fileURLWithPath: "/shoots/one/a.mp4")
    private let b = URL(fileURLWithPath: "/shoots/one/b.mp4")
    private let folder = URL(fileURLWithPath: "/shoots/one", isDirectory: true)

    private struct Rig {
        let memory: ColorMemory
        let folders: FolderColors
        let files: ResumeStore
    }

    private func rig() -> Rig {
        let folders = FolderColors(url: nil)
        let files = ResumeStore(url: makeTemporaryDirectory().appendingPathComponent("positions.json"))
        return Rig(memory: ColorMemory(folders: folders, files: files), folders: folders, files: files)
    }

    private func config(_ pairs: [String: String]) -> Config { Config().applying(pairs).config }

    @Test func nothingOpenSaysSoEverywhere() {
        let r = rig()
        let none = ColorMemory.Outcome(osd: "No video open", globalWrites: [:], haptic: .error)
        #expect(r.memory.toggle(.autoColor, global: Config()) == none)
        #expect(r.memory.toggle(.vibrance, global: Config()) == none)
        #expect(r.memory.addStrength(0.05, global: Config()) == none)
        #expect(r.memory.save(.autoColor, on: nil, global: Config()) == none)
        #expect(r.memory.save(.vibrance, on: .folder, global: Config()) == none)
        #expect(r.memory.reset(.file) == none)
        #expect(!r.memory.hasOwn(.file) && !r.memory.hasOwn(.folder))
        r.memory.open(a, size: 10)
        r.memory.open(nil, size: nil)
        #expect(r.memory.reset(.folder) == none)
    }

    @Test func toggleWritesTheFileOnlyNotItsSibling() {
        let r = rig()
        r.memory.open(a, size: 10)
        let out = r.memory.toggle(.autoColor, global: Config())
        #expect(out.osd == "Auto colour: on · file" && out.globalWrites.isEmpty)
        #expect(r.files.color(for: a, size: 10) == ["auto-color": "yes"])
        #expect(r.memory.effective(global: Config()).config.autoColor)
        #expect(r.memory.effective(global: Config()).origin == .file)
        #expect(r.folders.own(for: folder).isEmpty)
        r.memory.open(b, size: 20)                         // the sibling of the same folder
        #expect(!r.memory.effective(global: Config()).config.autoColor)
        #expect(r.memory.effective(global: Config()).origin == .default)
        #expect(r.files.color(for: b, size: 20) == nil)
        r.memory.open(a, size: 10)                         // and back: remembered
        #expect(r.memory.effective(global: Config()).config.autoColor)
    }

    @Test func toggleOffAndVibranceUseTheirOwnTexts() {
        let r = rig()
        r.memory.open(a, size: 10)
        let global = config(["auto-color": "yes"])
        #expect(r.memory.toggle(.autoColor, global: global).osd == "Auto colour: off · file")
        #expect(r.files.color(for: a, size: 10) == ["auto-color": "no"])
        #expect(r.memory.toggle(.vibrance, global: global).osd == "Vibrance: on · file")
        #expect(r.memory.toggle(.vibrance, global: global).osd == "Vibrance: off · file")
        #expect(r.files.color(for: a, size: 10) == ["auto-color": "no", "vibrance-on": "no"])
    }

    @Test func toggleWritesEvenWhenTheValueEqualsTheInheritedOne() {
        let r = rig()
        r.folders.set(["vibrance-on": "no"], for: folder)
        r.memory.open(a, size: 10)
        let global = config(["vibrance-on": "yes"])
        // Effective is off (folder); toggling gives on, which equals the default: still pinned on the file.
        #expect(r.memory.toggle(.vibrance, global: global).osd == "Vibrance: on · file")
        #expect(r.files.color(for: a, size: 10) == ["vibrance-on": "yes"])
        // Turning it off again equals the folder's value: pinned too.
        #expect(r.memory.toggle(.vibrance, global: global).osd == "Vibrance: off · file")
        #expect(r.files.color(for: a, size: 10) == ["vibrance-on": "no"])
    }

    @Test func addStrengthStepsFromTheEffectiveValueAndWritesTheFile() {
        let r = rig()
        r.memory.open(a, size: 10)
        let global = config(["auto-color": "yes", "auto-color-strength": "0.6"])
        let up = r.memory.addStrength(0.05, global: global)
        #expect(up.osd == "Auto colour strength 0.65 · file" && up.haptic == .step && up.globalWrites.isEmpty)
        #expect(r.files.color(for: a, size: 10) == ["auto-color-strength": "0.65"])
        #expect(r.memory.addStrength(-0.05, global: global).osd == "Auto colour strength 0.60 · file")
        #expect(r.memory.addStrength(-0.05, global: global).osd == "Auto colour strength 0.55 · file")
        #expect(r.memory.addStrength(-0.05, global: global).haptic == .detent)       // 0.55 -> 0.50 lands on a detent
        #expect(r.memory.addStrength(-0.05, global: Config()).osd == "Auto colour strength 0.45 · file (off)")
    }

    @Test func addStrengthAtTheBoundWritesNothing() {
        let r = rig()
        r.memory.open(a, size: 10)
        let out = r.memory.addStrength(0.05, global: Config())      // strength 1.0 by default
        #expect(out.haptic == .limit && out.osd == "Auto colour strength 1.00 · file (off)")
        #expect(r.files.color(for: a, size: 10) == nil)
        #expect(!r.memory.hasOwn(.file))
        let low = r.memory.addStrength(-1.05, global: Config())       // past 0: clamps to 0 and writes
        #expect(low.haptic == .limit && r.files.color(for: a, size: 10) == ["auto-color-strength": "0"])
        #expect(r.memory.addStrength(-0.05, global: Config()).haptic == .limit)
        #expect(r.files.color(for: a, size: 10) == ["auto-color-strength": "0"])
    }

    @Test func saveForTheFolderLetsTheSiblingInheritAndKeepsThePicture() {
        let r = rig()
        r.memory.open(a, size: 10)
        let global = config(["auto-color-strength": "0.6"])
        _ = r.memory.toggle(.autoColor, global: global)                     // file: auto-color yes
        _ = r.memory.addStrength(0.05, global: global)                      // file: strength 0.65
        let before = r.memory.effective(global: global)
        let out = r.memory.save(.autoColor, on: .folder, global: global)
        #expect(out.osd == "Auto colour saved for the folder" && out.globalWrites.isEmpty)
        #expect(r.folders.own(for: folder) == ["auto-color": "yes", "auto-color-strength": "0.65"])
        #expect(r.files.color(for: a, size: 10) == nil)                     // now redundant, cleared
        #expect(r.memory.effective(global: global).config == before.config)
        r.memory.open(b, size: 20)
        let sibling = r.memory.effective(global: global)
        #expect(sibling.config.autoColor && sibling.config.autoColorStrength == 0.65 && sibling.origin == .folder)
        #expect(r.memory.hasOwn(.folder) && !r.memory.hasOwn(.file))
    }

    @Test func saveVibranceForTheFolderWritesItsPairOnly() {
        let r = rig()
        r.memory.open(a, size: 10)
        _ = r.memory.toggle(.vibrance, global: Config())
        let out = r.memory.save(.vibrance, on: .folder, global: Config())
        #expect(out.osd == "Vibrance saved for the folder")
        #expect(r.folders.own(for: folder) == ["vibrance-on": "yes", "vibrance": "0.5"])
    }

    @Test func defaultSaveReturnsTheWritesAndFinishClearsTheRedundantFileValues() {
        let r = rig()
        r.memory.open(a, size: 10)
        let global = config(["auto-color-strength": "0.6"])
        _ = r.memory.toggle(.autoColor, global: global)
        _ = r.memory.addStrength(0.05, global: global)
        _ = r.memory.toggle(.vibrance, global: global)                      // other set: must stay
        let before = r.memory.effective(global: global)
        let out = r.memory.save(.autoColor, on: nil, global: global)
        #expect(out.osd == "Auto colour saved as default")
        #expect(out.globalWrites == ["auto-color": "yes", "auto-color-strength": "0.65"])
        #expect(r.files.color(for: a, size: 10)?.count == 3)                // nothing touched before the app wrote
        let newGlobal = global.applying(out.globalWrites).config
        r.memory.finishDefaultSave(.autoColor, global: global)
        #expect(r.files.color(for: a, size: 10) == ["vibrance-on": "yes"])
        #expect(r.memory.effective(global: newGlobal).config == before.config)
    }

    @Test func defaultSaveClearsTheFolderValuesThatTheNewDefaultSays() {
        let r = rig()
        r.folders.set(["auto-color": "yes", "auto-color-strength": "0.3"], for: folder)
        r.memory.open(a, size: 10)
        let global = config(["auto-color-strength": "0.6"])
        let out = r.memory.save(.autoColor, on: nil, global: global)
        #expect(out.globalWrites == ["auto-color": "yes", "auto-color-strength": "0.3"])
        r.memory.finishDefaultSave(.autoColor, global: global)
        #expect(r.folders.own(for: folder).isEmpty)
    }

    @Test func resetFileBringsBackTheFolderValue() {
        let r = rig()
        r.folders.set(["auto-color-strength": "0.4"], for: folder)
        r.memory.open(a, size: 10)
        _ = r.memory.addStrength(0.05, global: Config())
        #expect(r.memory.effective(global: Config()).config.autoColorStrength == 0.45)
        #expect(r.memory.hasOwn(.file))
        let out = r.memory.reset(.file)
        #expect(out == ColorMemory.Outcome(osd: "File colour reset", globalWrites: [:], haptic: nil))
        #expect(r.memory.effective(global: Config()).config.autoColorStrength == 0.4)
        #expect(!r.memory.hasOwn(.file) && r.files.color(for: a, size: 10) == nil)
    }

    @Test func resetFolderFallsBackToTheDefault() {
        let r = rig()
        r.folders.set(["auto-color": "yes"], for: folder)
        r.memory.open(a, size: 10)
        #expect(r.memory.hasOwn(.folder))
        #expect(r.memory.reset(.folder).osd == "Folder colour reset")
        #expect(r.folders.own(for: folder).isEmpty && !r.memory.hasOwn(.folder))
        #expect(!r.memory.effective(global: Config()).config.autoColor)
    }

    @Test func aFileWithoutAReadableSizeKeepsItsEditsUntilClosed() {
        let r = rig()
        let gone = URL(fileURLWithPath: "/no/such/file.mp4")
        r.memory.open(gone, size: nil)
        #expect(r.memory.toggle(.autoColor, global: Config()).osd == "Auto colour: on · file")
        #expect(r.memory.effective(global: Config()).config.autoColor)
        #expect(!FileManager.default.fileExists(atPath: r.files.url.path))
    }

    @Test func worksWithoutAFileStore() {
        let memory = ColorMemory(folders: FolderColors(url: nil), files: nil)
        memory.open(a, size: 10)
        #expect(memory.toggle(.vibrance, global: Config()).osd == "Vibrance: on · file")
        #expect(memory.effective(global: Config()).config.vibranceOn)
    }

    @Test func aStoredValueConfigRefusesDoesNotDraw() {
        let r = rig()
        r.folders.set(["auto-color-strength": "lots", "vibrance": "0.2"], for: folder)
        r.memory.open(a, size: 10)
        let result = r.memory.effective(global: config(["auto-color-strength": "0.6"]))
        #expect(result.config.autoColorStrength == 0.6 && result.config.vibrance == 0.2)
        #expect(ColorMemory.loggedRejections.contains("auto-color-strength=lots"))
    }
}
