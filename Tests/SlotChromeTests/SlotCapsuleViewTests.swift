import AppKit
import Testing
@testable import SlotChrome

/// The capsule's filter field (final review of 2026-10-28: I1, I2).
@MainActor @Suite(.serialized) struct SlotCapsuleViewTests {
    private func window(with capsule: SlotCapsuleView) -> (NSWindow, NSTextField) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it
        let other = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        capsule.frame = NSRect(x: 6, y: 160, width: 388, height: SlotCapsuleView.height)
        window.contentView?.addSubview(capsule)
        window.contentView?.addSubview(other)
        capsule.setVisible(true, animated: false)
        return (window, other)
    }

    /// Closing the field from code (a tab switch, a hide) is not the user's Esc, which hides the slot.
    @Test func closingTheFieldFromCodeIsNotEscape() {
        let capsule = SlotCapsuleView(edge: .right)
        let (window, _) = window(with: capsule)
        var escapes = 0, closes = 0
        capsule.onFilterEnd = { escapes += 1 }
        capsule.onFilterClosed = { closes += 1 }
        capsule.beginFilter(text: "abc")
        #expect(capsule.isEditingFilter)
        capsule.closeFilter()
        #expect(!capsule.isEditingFilter)
        #expect(escapes == 0 && closes == 1)
        window.close()
    }

    /// The keys going elsewhere (a click on the video) close the field, so it does not stay up over the tabs and keep
    /// the capsule held.
    @Test func losingTheKeyboardClosesTheField() {
        let capsule = SlotCapsuleView(edge: .right)
        let (window, other) = window(with: capsule)
        var escapes = 0
        capsule.onFilterEnd = { escapes += 1 }
        capsule.beginFilter(text: "")
        #expect(capsule.isEditingFilter)
        window.makeFirstResponder(other)
        #expect(!capsule.isEditingFilter)
        #expect(escapes == 0)
        window.close()
    }
}
