import AppKit
import Carbon.HIToolbox

@MainActor
enum Actions {
    static func perform(_ action: ButtonAction) {
        switch action {
        case .none: break
        case .middleClick: click(button: 2)
        // shortcut: cmd+[ / cmd+] only works in apps that bind them (browsers, Finder, Xcode), upgrade to app-specific events if users ask
        case .back: key(kVK_ANSI_LeftBracket, .maskCommand)
        case .forward: key(kVK_ANSI_RightBracket, .maskCommand)
        case .missionControl:
            if !open("/System/Applications/Mission Control.app") { key(kVK_UpArrow, .maskControl) }
        // shortcut: keys follow the user's Keyboard > Shortcuts settings and fail if they were changed or disabled, upgrade when a public API exists
        case .appExpose: key(kVK_DownArrow, .maskControl)
        case .showDesktop: key(kVK_F11, [])
        case .spaceLeft: key(kVK_LeftArrow, .maskControl)
        case .spaceRight: key(kVK_RightArrow, .maskControl)
        case .launchpad:
            // macOS 26 replaced Launchpad with the Apps app.
            _ = open("/System/Applications/Launchpad.app") || open("/System/Applications/Apps.app")
        case .lookUp: key(kVK_ANSI_D, [.maskControl, .maskCommand])
        case .smartZoom:
            // shortcut: the two-finger double tap gesture can't be synthesized, so this toggles cmd+= / cmd+0 with one global flag; upgrade if a gesture API appears
            key(zoomed ? kVK_ANSI_0 : kVK_ANSI_Equal, .maskCommand)
            zoomed.toggle()
        case .volumeUp: mediaKey(0) // NX_KEYTYPE_SOUND_UP
        case .volumeDown: mediaKey(1) // NX_KEYTYPE_SOUND_DOWN
        case .playPause: mediaKey(16) // NX_KEYTYPE_PLAY
        case .nextTrack: mediaKey(17) // NX_KEYTYPE_NEXT
        case .previousTrack: mediaKey(18) // NX_KEYTYPE_PREVIOUS
        case .shortcut(let s): key(Int(s.keyCode), CGEventFlags(rawValue: s.modifiers))
        }
    }

    /// Media keys are system-defined events (subtype 8), not key codes; this is how the keyboard's F10–F12 / F8 reach the system.
    private static func mediaKey(_ code: Int) {
        for down in [true, false] {
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: data1, data2: -1)?.cgEvent.map { EventTap.post($0) }
        }
    }

    private static var zoomed = false

    /// Posts a full click of `button` at the pointer; tagged, so the tap does not reprocess it.
    static func click(button: Int64) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: .center) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: button)
            EventTap.post(e)
        }
    }

    private static let fnKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                            kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    static func key(_ code: Int, _ flags: CGEventFlags) {
        // System hotkeys for arrows and F-keys are registered with the fn flag, as real keyboards send it.
        let flags = fnKeys.contains(code) ? flags.union(.maskSecondaryFn) : flags
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.flags = flags
            EventTap.post(e)
        }
    }

    private static func open(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) && NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
