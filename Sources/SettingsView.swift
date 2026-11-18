import SwiftUI
import AppKit
import ServiceManagement
import ApplicationServices

struct SettingsView: View {
    private enum Tab: String, CaseIterable { case General, Buttons, Scrolling, About }
    @State private var tab = Tab.General

    // Segmented header instead of TabView: TabView's bordered box clashes with grouped Forms.
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .General: GeneralTab()
            case .Buttons: ButtonsTab()
            case .Scrolling: ScrollingTab()
            case .About: AboutTab()
            }
        }
        .frame(width: 500, height: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Enable Mouse Up", isOn: $store.settings.enabled)
            VStack(alignment: .leading) {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading) {
                Toggle("Show menu bar icon", isOn: $store.settings.showMenuBarIcon)
                Text("When hidden, open Mouse Up again to show this window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Accessibility") {
                if AXIsProcessTrusted() {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant Access…") { Permissions.begin() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Buttons

private struct ButtonsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var monitor: Any?
    @State private var note: String?

    var body: some View {
        Form {
            ForEach($store.settings.buttons) { $mapping in
                Section {
                    ActionPicker(title: "Click", action: $mapping.click)
                    ActionPicker(title: "Double click", action: $mapping.doubleClick)
                    ActionPicker(title: "Triple click", action: $mapping.tripleClick)
                    ActionPicker(title: "Hold", action: $mapping.hold)
                    ActionPicker(title: "Hold and scroll up", action: $mapping.scrollUp)
                    ActionPicker(title: "Hold and scroll down", action: $mapping.scrollDown)
                    Picker("Click and drag", selection: $mapping.drag) {
                        ForEach(DragAction.allCases) { Text($0.label).tag($0) }
                    }
                    if mapping.drag == .custom {
                        ActionPicker(title: "Drag up", action: $mapping.dragUp)
                        ActionPicker(title: "Drag down", action: $mapping.dragDown)
                        ActionPicker(title: "Drag left", action: $mapping.dragLeft)
                        ActionPicker(title: "Drag right", action: $mapping.dragRight)
                    }
                } header: {
                    HStack {
                        Text(buttonName(mapping.button))
                        Spacer()
                        Button(role: .destructive) {
                            store.settings.buttons.removeAll { $0.button == mapping.button }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this button")
                    }
                }
            }
            Section {
                HStack {
                    if monitor == nil {
                        Button("Add Button…", action: startCapture)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Press the mouse button you want to add…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", action: stopCapture)
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Buttons that are not listed keep their normal behavior.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stopCapture)
    }

    private func startCapture() {
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            let button = Int64(event.buttonNumber)
            if button == 2 {
                note = "The wheel button always keeps its normal behavior."
            } else if store.settings.mapping(for: button) != nil {
                note = "\(buttonName(button)) is already in the list."
            } else {
                store.settings.buttons.append(ButtonMapping(button: button))
                store.settings.buttons.sort { $0.button < $1.button }
            }
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private func buttonName(_ button: Int64) -> String {
    switch button {
    case 2: return "Middle Button"
    case 3: return "Button 4 (Back)"
    case 4: return "Button 5 (Forward)"
    default: return "Button \(button + 1)"
    }
}

private struct ActionPicker: View {
    let title: String
    @Binding var action: ButtonAction
    @State private var recording = false
    private static let shortcutTag = -1

    var body: some View {
        HStack {
            Picker(title, selection: Binding(get: selection, set: select)) {
                ForEach(ButtonAction.presets.indices, id: \.self) { Text(ButtonAction.presets[$0].label).tag($0) }
                Divider()
                Text("Keyboard Shortcut").tag(Self.shortcutTag)
            }
            if recording || action.shortcut != nil {
                ShortcutRecorder(action: $action, recording: $recording)
            }
        }
    }

    private func selection() -> Int {
        recording || action.shortcut != nil ? Self.shortcutTag : ButtonAction.presets.firstIndex(of: action) ?? 0
    }

    private func select(_ tag: Int) {
        if tag == Self.shortcutTag {
            if action.shortcut == nil { recording = true }
        } else {
            recording = false
            action = ButtonAction.presets[tag]
        }
    }
}

/// Click, then press a key combination. Esc cancels.
private struct ShortcutRecorder: View {
    @Binding var action: ButtonAction
    @Binding var recording: Bool
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type shortcut…" : action.shortcut.map(\.display) ?? "Record") { recording.toggle() }
            .frame(minWidth: 110)
            .onChange(of: recording) { $0 ? start() : stop() }
            .onAppear { if recording { start() } }
            .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != 53 { // 53 = Escape
                // NSEvent modifier bits for ⇧⌃⌥⌘ have the same raw values as CGEventFlags.
                let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
                action = .shortcut(KeyShortcut(keyCode: event.keyCode, modifiers: UInt64(mods.rawValue)))
            }
            recording = false
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Scrolling

private struct ScrollingTab: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Smoothness", selection: $store.settings.scroll.smoothness) {
                    ForEach(Smoothness.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Speed", selection: $store.settings.scroll.speed) {
                    ForEach(ScrollSpeed.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Acceleration", isOn: $store.settings.scroll.acceleration)
                Toggle("Precise when scrolling slowly", isOn: $store.settings.scroll.preciseWhenSlow)
                Toggle("Simulate trackpad", isOn: $store.settings.scroll.simulateTrackpad)
                    .help("Smooth scrolling behaves like a trackpad: momentum, rubber banding and swipe gestures in apps.")
            }
            Section("Direction") {
                Toggle("Reverse vertical scrolling", isOn: $store.settings.scroll.reverseVertical)
                Toggle("Reverse horizontal scrolling", isOn: $store.settings.scroll.reverseHorizontal)
            }
            Section {
                ModifierPicker(title: "Precise scrolling", key: $store.settings.scroll.preciseModifier)
                ModifierPicker(title: "Horizontal scrolling", key: $store.settings.scroll.horizontalModifier)
                ModifierPicker(title: "Zoom", key: $store.settings.scroll.zoomModifier)
                ModifierPicker(title: "Fast scrolling", key: $store.settings.scroll.swiftModifier)
            } header: {
                Text("Hold While Scrolling")
            } footer: {
                Text("Only affects mouse wheels. Trackpads and Magic Mouse are left untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModifierPicker: View {
    let title: String
    @Binding var key: ModifierKey

    var body: some View {
        Picker(title, selection: $key) {
            ForEach(ModifierKey.allCases) { Text($0.label).tag($0) }
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Mouse Up").font(.largeTitle.bold())
            Text(version).foregroundStyle(.secondary)
            Text("Smooth scrolling and button remapping for any mouse.")
            Text("Free and open source under the MIT License.\nCopyright © 2026 Carlos Alberto.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Link("View on GitHub", destination: URL(string: "https://github.com/CarlosAllberto/mouse-up")!)
                .padding(.top, 6)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Labels

extension ButtonAction {
    static let presets: [ButtonAction] = [
        .none, .middleClick, .back, .forward, .missionControl, .appExpose, .showDesktop,
        .launchpad, .spaceLeft, .spaceRight, .lookUp, .smartZoom,
        .volumeUp, .volumeDown, .playPause, .nextTrack, .previousTrack,
    ]

    var shortcut: KeyShortcut? {
        if case .shortcut(let s) = self { return s }
        return nil
    }

    var label: String {
        switch self {
        case .none: return "None"
        case .middleClick: return "Middle Click"
        case .back: return "Back"
        case .forward: return "Forward"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .spaceLeft: return "Space Left"
        case .spaceRight: return "Space Right"
        case .lookUp: return "Look Up"
        case .smartZoom: return "Smart Zoom"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .shortcut(let s): return s.display
        }
    }
}

extension DragAction {
    var label: String {
        switch self {
        case .none: return "Normal (app default)"
        case .missionControlAndSpaces: return "Mission Control & Spaces"
        case .scrollAndNavigate: return "Scroll & Navigate"
        case .custom: return "Custom Directions"
        }
    }
}

extension ModifierKey {
    var label: String {
        switch self {
        case .none: return "Off"
        case .option: return "⌥ Option"
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        }
    }
}

extension KeyShortcut {
    var display: String {
        let flags = CGEventFlags(rawValue: modifiers)
        let mods = [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
        return mods + keyName
    }

    private var keyName: String {
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[keyCode] { return name }
        // Let the current keyboard layout name the key.
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let chars = event.flatMap { NSEvent(cgEvent: $0) }?.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "Key \(keyCode)" : chars.uppercased()
    }
}
