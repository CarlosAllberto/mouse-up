import AppKit

/// Per-button click / double click / hold / drag state machine.
@MainActor
final class ButtonEngine {
    static let shared = ButtonEngine()

    static let holdDelay = 0.35       // s
    static let dragStart = 5.0        // px of movement before a press becomes a drag
    nonisolated static let gestureThreshold = 40.0 // px of drag before a Mission Control & Spaces gesture fires

    private struct Press {
        let mapping: ButtonMapping
        let origin: CGPoint
        var dx = 0.0, dy = 0.0
        var dragging = false
        var clickNumber = 1 // 2nd/3rd press of a multi-click
        var consumed = false // hold, double click or drag already used this press
        var gestureFired = false
        var scrolling = false
        var holdTask: Task<Void, Never>?
    }

    private var presses: [Int64: Press] = [:]
    private var pendingClick: [Int64: Task<Void, Never>] = [:]
    private var clickCount: [Int64: Int] = [:] // clicks finished while waiting for the next one

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown: return down(button, event)
        case .otherMouseDragged: return dragged(button, event)
        case .otherMouseUp: return up(button, event)
        default: return event
        }
    }

    /// Wheel tick while a button with scroll actions is held: run the action, swallow the tick,
    /// and mark the press used so releasing it does not also click.
    func scrolled(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              let (button, p) = presses.first(where: { $0.value.mapping.hasScroll }) else { return false }
        let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        guard delta != 0 else { return true }
        // Natural scrolling flips the delta; undo it so "up" means pushing the wheel away.
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        Actions.perform((delta > 0) != inverted ? p.mapping.scrollUp : p.mapping.scrollDown)
        p.holdTask?.cancel()
        presses[button]?.consumed = true
        return true
    }

    private func down(_ button: Int64, _ event: CGEvent) -> CGEvent? {
        guard let m = SettingsStore.shared.settings.mapping(for: button), !m.isPassThrough else { return event }
        presses[button] = Press(mapping: m, origin: event.location)
        if m.isInstant {
            if m.click == .middleClick { return asMiddle(event) }
            Actions.perform(m.click)
            return nil
        }
        if let pending = pendingClick.removeValue(forKey: button) {
            pending.cancel()
            let n = (clickCount[button] ?? 1) + 1
            presses[button]?.clickNumber = n
            if n >= m.maxClicks { // nothing longer can follow: fire now
                presses[button]?.consumed = true
                clickCount[button] = nil
                fire(n, m)
                return nil
            }
        }
        if m.hold != .none {
            presses[button]?.holdTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.holdDelay * 1e9))
                guard !Task.isCancelled, let self, self.presses[button]?.consumed == false else { return }
                self.presses[button]?.consumed = true
                Actions.perform(m.hold)
            }
        }
        return nil
    }

    private func dragged(_ button: Int64, _ event: CGEvent) -> CGEvent? {
        guard var p = presses[button] else { return event }
        if p.mapping.isInstant && p.mapping.click == .middleClick { return asMiddle(event) }
        guard p.mapping.drag != .none, !p.consumed || p.dragging else { return event }
        let ddx = event.getDoubleValueField(.mouseEventDeltaX), ddy = event.getDoubleValueField(.mouseEventDeltaY)
        p.dx += ddx
        p.dy += ddy
        defer { presses[button] = p }
        if !p.dragging {
            guard hypot(p.dx, p.dy) > Self.dragStart else { return nil }
            p.dragging = true
            p.consumed = true
            p.holdTask?.cancel()
            // Freeze the pointer during the gesture; deltas keep arriving in the drag events.
            CGAssociateMouseAndMouseCursorPosition(0)
            CGWarpMouseCursorPosition(p.origin)
        }
        switch p.mapping.drag {
        case .missionControlAndSpaces, .custom:
            let m = p.mapping
            // Horizontal works like a trackpad swipe: dragging left shows the Space on the right.
            let (up, down, left, right): (ButtonAction, ButtonAction, ButtonAction, ButtonAction) = m.drag == .custom
                ? (m.dragUp, m.dragDown, m.dragLeft, m.dragRight)
                : (.missionControl, .appExpose, .spaceRight, .spaceLeft)
            if !p.gestureFired, let dir = Self.classify(dx: p.dx, dy: p.dy) {
                p.gestureFired = true
                Actions.perform([up, down, left, right][dir.rawValue])
            }
        case .scrollAndNavigate:
            postScroll(dx: ddx, dy: ddy, phase: p.scrolling ? .changed : .began)
            p.scrolling = true
        case .none: break
        }
        return nil
    }

    private func up(_ button: Int64, _ event: CGEvent) -> CGEvent? {
        guard let p = presses.removeValue(forKey: button) else { return event }
        p.holdTask?.cancel()
        if p.dragging {
            CGAssociateMouseAndMouseCursorPosition(1)
            if p.scrolling { postScroll(dx: 0, dy: 0, phase: .ended) }
            return nil
        }
        if p.mapping.isInstant { return p.mapping.click == .middleClick ? asMiddle(event) : nil }
        if p.consumed { return nil }
        let m = p.mapping, n = p.clickNumber
        if n >= m.maxClicks {
            fire(n, m)
        } else {
            clickCount[button] = n
            pendingClick[button] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(NSEvent.doubleClickInterval * 1e9))
                guard !Task.isCancelled, let self else { return }
                self.pendingClick[button] = nil
                self.clickCount[button] = nil
                self.fire(n, m)
            }
        }
        return nil
    }

    /// Runs the action for an n-click; an unassigned count replays n plain clicks.
    private func fire(_ n: Int, _ m: ButtonMapping) {
        let action = n == 3 ? m.tripleClick : n == 2 ? m.doubleClick : .none
        if action == .none { for _ in 0..<n { click(m) } } else { Actions.perform(action) }
    }

    /// A `.none` click on a button that has other triggers replays the button's own click.
    private func click(_ m: ButtonMapping) {
        if m.click == .none { Actions.click(button: m.button) } else { Actions.perform(m.click) }
    }

    /// Zero-latency middle-click remap: rewrite the button number so holding/dragging still works natively.
    private func asMiddle(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        return event
    }

    /// Pixel, phased scroll so apps treat it like a trackpad; content follows the pointer.
    private func postScroll(dx: Double, dy: Double, phase: CGScrollPhase) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        EventTap.post(e)
    }

    enum Direction: Int { case up, down, left, right }

    nonisolated static func classify(dx: Double, dy: Double) -> Direction? {
        guard max(abs(dx), abs(dy)) >= gestureThreshold else { return nil }
        if abs(dx) > abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down // CG y grows downward
    }

    nonisolated static func selfTest() {
        assert(ButtonMapping(button: 3, click: .back).maxClicks == 1)
        assert(ButtonMapping(button: 3, doubleClick: .playPause).maxClicks == 2)
        assert(ButtonMapping(button: 3, tripleClick: .nextTrack).maxClicks == 3)
        assert(classify(dx: 10, dy: -20) == nil)
        assert(classify(dx: 0, dy: -50) == .up)
        assert(classify(dx: 5, dy: 45) == .down)
        assert(classify(dx: -60, dy: 30) == .left)
        assert(classify(dx: 41, dy: -40) == .right)
    }
}

private extension ButtonMapping {
    var hasScroll: Bool { scrollUp != .none || scrollDown != .none }
    /// Longest multi-click with an action; the engine stops waiting once it is reached.
    var maxClicks: Int { tripleClick != .none ? 3 : doubleClick != .none ? 2 : 1 }
    var isPassThrough: Bool { click == .none && doubleClick == .none && tripleClick == .none && hold == .none && drag == .none && !hasScroll }
    /// Only `click` set: act on mouse-down, nothing to wait for.
    var isInstant: Bool { doubleClick == .none && tripleClick == .none && hold == .none && drag == .none && !hasScroll }
}
