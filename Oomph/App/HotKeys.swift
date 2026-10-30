import AppKit
import Carbon.HIToolbox

/// What the global shortcuts do.
enum ShortcutAction: String, CaseIterable {
    case toggleEQ, nextPreset, previousPreset

    var title: String {
        switch self {
        case .toggleEQ: "Turn the EQ on or off"
        case .nextPreset: "Next preset"
        case .previousPreset: "Previous preset"
        }
    }

    /// Where Settings keeps this action's shortcut.
    var defaultsKey: String { "shortcut.\(rawValue)" }
}

/// A key with modifiers, recorded in Settings for a global shortcut.
struct Shortcut: Hashable {
    let keyCode: UInt32
    /// ⌃ ⌥ ⇧ ⌘ only, as `NSEvent.ModifierFlags` raw values.
    let modifiers: UInt
    /// The key as printed on the keyboard: "E", "→", "F5".
    let key: String

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined() + key
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
            .filter { flags.contains($0.0) }.reduce(0) { $0 | UInt32($1.1) }
    }

    /// Keys whose characters don't print.
    private static let keyNames: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

extension Shortcut {
    /// The key pressed, if it has ⌘, ⌥ or ⌃: without one, a global shortcut would take the key
    /// away from typing in every app.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.isDisjoint(with: [.control, .option, .command]) else { return nil }
        let typed = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        let prints = !typed.isEmpty && typed.unicodeScalars.allSatisfy {
            ![.control, .privateUse, .spaceSeparator].contains($0.properties.generalCategory)
        }
        guard let key = Self.keyNames[Int(event.keyCode)] ?? (prints ? typed : nil) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, key: key)
    }
}

/// Stored as "<key code> <modifiers> <key>", for `@AppStorage`.
extension Shortcut: RawRepresentable {
    var rawValue: String { "\(keyCode) \(modifiers) \(key)" }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, let keyCode = UInt32(parts[0]), let modifiers = UInt(parts[1]) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: String(parts[2]))
    }
}

/// Registers the shortcuts saved in Settings with the system, so they work in every app.
/// Carbon's hot keys need no Accessibility permission, unlike a global key monitor.
@MainActor
final class HotKeys {
    var onPress: ((ShortcutAction) -> Void)?
    private var registered: [ShortcutAction: Shortcut] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private nonisolated static let signature: OSType = 0x4F6F_6D70 // "Oomp"

    /// Registers the shortcuts Settings has saved, if they changed since the last call.
    func reload(from defaults: UserDefaults = .standard) {
        var saved: [ShortcutAction: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            saved[action] = defaults.string(forKey: action.defaultsKey).flatMap(Shortcut.init(rawValue:))
        }
        guard saved != registered else { return }
        registered = saved
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if handler == nil { installHandler() }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = saved[action] else { continue }
            var ref: EventHotKeyRef?
            RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
    }

    /// ponytail: the handler and this object live as long as the app, so neither is released.
    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let context, id.signature == HotKeys.signature, ShortcutAction.allCases.indices.contains(Int(id.id)) else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKeys.onPress?(ShortcutAction.allCases[Int(id.id)]) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
