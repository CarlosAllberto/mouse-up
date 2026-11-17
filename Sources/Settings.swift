import Foundation
import CoreGraphics
import Combine

enum ModifierKey: String, Codable, CaseIterable, Identifiable {
    case none, option, shift, command, control
    var id: String { rawValue }

    var flag: CGEventFlags? {
        switch self {
        case .none: return nil
        case .option: return .maskAlternate
        case .shift: return .maskShift
        case .command: return .maskCommand
        case .control: return .maskControl
        }
    }
}

enum Smoothness: String, Codable, CaseIterable, Identifiable { case off, regular, high; var id: String { rawValue } }
enum ScrollSpeed: String, Codable, CaseIterable, Identifiable { case slow, medium, fast; var id: String { rawValue } }

struct ScrollSettings: Codable, Equatable {
    var smoothness: Smoothness = .regular
    var speed: ScrollSpeed = .medium
    var acceleration = true
    var reverseVertical = false
    var reverseHorizontal = false
    var preciseModifier: ModifierKey = .option
    var horizontalModifier: ModifierKey = .shift
    var zoomModifier: ModifierKey = .command
    var swiftModifier: ModifierKey = .control
    var preciseWhenSlow = true // a lone, slow wheel tick scrolls a small precise step
}

extension ScrollSettings {
    /// Missing keys fall back to defaults, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ value: inout T) throws {
            if let v = try c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        try load(.smoothness, &smoothness); try load(.speed, &speed); try load(.acceleration, &acceleration)
        try load(.reverseVertical, &reverseVertical); try load(.reverseHorizontal, &reverseHorizontal)
        try load(.preciseModifier, &preciseModifier); try load(.horizontalModifier, &horizontalModifier)
        try load(.zoomModifier, &zoomModifier); try load(.swiftModifier, &swiftModifier)
        try load(.preciseWhenSlow, &preciseWhenSlow)
    }
}

struct KeyShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt64 // CGEventFlags.rawValue
}

enum ButtonAction: Codable, Equatable, Hashable {
    case none, middleClick, back, forward
    case missionControl, appExpose, showDesktop, launchpad
    case spaceLeft, spaceRight, lookUp, smartZoom
    case volumeUp, volumeDown, playPause, nextTrack, previousTrack
    case shortcut(KeyShortcut)
}

enum DragAction: String, Codable, CaseIterable, Identifiable {
    case none, missionControlAndSpaces, scrollAndNavigate, custom
    var id: String { rawValue }
}

struct ButtonMapping: Codable, Equatable, Identifiable {
    var button: Int64 // CGEvent .mouseEventButtonNumber: 2 = middle, 3 = back, 4 = forward, 5+ extra
    var click: ButtonAction = .none
    var doubleClick: ButtonAction = .none
    var tripleClick: ButtonAction = .none
    var hold: ButtonAction = .none
    var drag: DragAction = .none
    var dragUp: ButtonAction = .none     // used when drag == .custom
    var dragDown: ButtonAction = .none
    var dragLeft: ButtonAction = .none
    var dragRight: ButtonAction = .none
    var scrollUp: ButtonAction = .none   // wheel up while the button is held
    var scrollDown: ButtonAction = .none // wheel down while the button is held
    var id: Int64 { button }
}

extension ButtonMapping {
    private enum CodingKeys: String, CodingKey { case button, click, doubleClick, tripleClick, hold, drag, dragUp, dragDown, dragLeft, dragRight, scrollUp, scrollDown }

    /// Missing keys fall back to defaults, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decode(Int64.self, forKey: .button)
        click = try c.decodeIfPresent(ButtonAction.self, forKey: .click) ?? .none
        doubleClick = try c.decodeIfPresent(ButtonAction.self, forKey: .doubleClick) ?? .none
        tripleClick = try c.decodeIfPresent(ButtonAction.self, forKey: .tripleClick) ?? .none
        hold = try c.decodeIfPresent(ButtonAction.self, forKey: .hold) ?? .none
        drag = try c.decodeIfPresent(DragAction.self, forKey: .drag) ?? .none
        dragUp = try c.decodeIfPresent(ButtonAction.self, forKey: .dragUp) ?? .none
        dragDown = try c.decodeIfPresent(ButtonAction.self, forKey: .dragDown) ?? .none
        dragLeft = try c.decodeIfPresent(ButtonAction.self, forKey: .dragLeft) ?? .none
        dragRight = try c.decodeIfPresent(ButtonAction.self, forKey: .dragRight) ?? .none
        scrollUp = try c.decodeIfPresent(ButtonAction.self, forKey: .scrollUp) ?? .none
        scrollDown = try c.decodeIfPresent(ButtonAction.self, forKey: .scrollDown) ?? .none
    }
}

struct Settings: Codable, Equatable {
    var enabled = true
    var showMenuBarIcon = true
    var scroll = ScrollSettings()
    var buttons: [ButtonMapping] = [
        ButtonMapping(button: 3, click: .back),
        ButtonMapping(button: 4, click: .forward),
    ]

    func mapping(for button: Int64) -> ButtonMapping? { buttons.first { $0.button == button } }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "settings.v1"

    @Published var settings: Settings {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
            // The wheel button is no longer configurable: remapping it broke native middle-click/drag in apps.
            settings.buttons.removeAll { $0.button == 2 }
        } else {
            settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
