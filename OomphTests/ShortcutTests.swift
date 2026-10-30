import AppKit
import Carbon.HIToolbox
import Testing
@testable import Oomph

struct ShortcutTests {
    private func press(_ characters: String, keyCode: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))!
    }

    @Test func recordsAKeyWithModifiers() throws {
        let shortcut = try #require(Shortcut(press("e", keyCode: kVK_ANSI_E, [.control, .option, .command])))
        #expect(shortcut.display == "⌃⌥⌘E")
        #expect(shortcut.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        let arrow = try #require(Shortcut(press("\u{F703}", keyCode: kVK_RightArrow, [.shift, .command, .function, .numericPad])))
        #expect(arrow.display == "⇧⌘→")
        #expect(arrow.carbonModifiers == UInt32(shiftKey | cmdKey))
    }

    /// A global shortcut without ⌘, ⌥ or ⌃ would take the key away from typing in every app.
    @Test func refusesKeysThatTypeText() {
        #expect(Shortcut(press("e", keyCode: kVK_ANSI_E, [])) == nil)
        #expect(Shortcut(press("E", keyCode: kVK_ANSI_E, [.shift])) == nil)
    }

    @Test func survivesStorage() throws {
        let shortcut = try #require(Shortcut(press("e", keyCode: kVK_ANSI_E, [.option, .command])))
        #expect(Shortcut(rawValue: shortcut.rawValue) == shortcut)
    }
}
