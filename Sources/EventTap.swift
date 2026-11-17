import Foundation
import CoreGraphics

/// Single session event tap. Runs on the main run loop, so handlers run on the main thread.
@MainActor
final class EventTap {
    static let shared = EventTap()
    /// Marks events we post ourselves so the tap passes them through untouched.
    static let syntheticTag: Int64 = 0x4D_55_50 // "MUP"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap != nil }

    static func post(_ event: CGEvent, tap location: CGEventTapLocation = .cghidEventTap) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        event.post(tap: location)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: eventTapCallback, userInfo: nil) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func route(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard SettingsStore.shared.settings.enabled,
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticTag else { return event }
        switch type {
        case .scrollWheel: return ButtonEngine.shared.scrolled(event) ? nil : ScrollEngine.shared.handle(event)
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: return ButtonEngine.shared.handle(type, event)
        default: return event
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            EventTap.shared.reenable()
            return Unmanaged.passUnretained(event)
        }
        guard let out = EventTap.shared.route(type, event) else { return nil }
        return out === event ? Unmanaged.passUnretained(event) : Unmanaged.passRetained(out)
    }
}
