import Foundation
import CoreGraphics

/// Turns discrete mouse-wheel ticks into trackpad-like scrolling (see SPEC "Scrolling").
@MainActor
final class ScrollEngine {
    static let shared = ScrollEngine()

    static let accelerationWindow = 0.12 // s between ticks that still counts as one fast streak
    static let gestureHold = 0.06        // s without ticks before the "fingers lift" and momentum starts

    private enum Phase { case idle, gesture, momentum }
    private var phase = Phase.idle
    private var beganPending = false, momentumPending = false
    private var remaining = (x: 0.0, y: 0.0) // pixels still to deliver
    private var carry = (x: 0.0, y: 0.0)     // sub-pixel leftovers, so no distance is lost to rounding
    private var lastTick = 0.0, lastFrame = 0.0
    private var lastDirection = 0, streak = 0
    private var flags: CGEventFlags = []
    private var tau = 0.06
    private var timer: Timer?

    func handle(_ event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return event }
        let s = SettingsStore.shared.settings.scroll
        let inFlags = event.flags
        func held(_ m: ModifierKey) -> Bool { m.flag.map { inFlags.contains($0) } ?? false }

        let rawY = Self.direction(event, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1)
        let rawX = Self.direction(event, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2)
        guard rawY != 0 || rawX != 0 else { return event }

        if held(s.zoomModifier) {
            zoom(in: (rawY != 0 ? rawY : rawX) > 0)
            return nil
        }

        var dy = s.reverseVertical ? -rawY : rawY
        var dx = s.reverseHorizontal ? -rawX : rawX
        var consumed: CGEventFlags = []
        let now = ProcessInfo.processInfo.systemUptime
        let slowTick = s.preciseWhenSlow && now - lastTick > Self.slowTickGap
        let precise = held(s.preciseModifier) || slowTick, swift = held(s.swiftModifier)
        if held(s.preciseModifier), let f = s.preciseModifier.flag { consumed.insert(f) }
        if swift, let f = s.swiftModifier.flag { consumed.insert(f) }
        if held(s.horizontalModifier), let f = s.horizontalModifier.flag {
            consumed.insert(f) // also stops apps from swapping axes a second time on Shift
            if dx == 0 { (dx, dy) = (dy, 0) }
        }

        let direction = dy != 0 ? (dy > 0 ? 1 : -1) : (dx > 0 ? 2 : -2)
        streak = direction == lastDirection && now - lastTick < Self.accelerationWindow ? streak + 1 : 0
        lastDirection = direction
        lastTick = now
        let px = Self.tickPixels(speed: s.speed, streak: s.acceleration ? streak : 0, precise: precise, swift: swift)
        let outFlags = inFlags.subtracting(consumed)

        if s.smoothness == .off {
            let lines = Int32(Self.lines(forPixels: px))
            guard let out = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                    wheel1: Int32(dy) * lines, wheel2: Int32(dx) * lines, wheel3: 0) else { return event }
            out.flags = outFlags
            return out
        }

        enqueue(x: dx * px, y: dy * px, flags: outFlags, tau: s.smoothness == .high ? 0.11 : 0.06, now: now)
        return nil
    }

    // MARK: - Animation

    private func enqueue(x: Double, y: Double, flags: CGEventFlags, tau: Double, now: Double) {
        if remaining.x * x < 0 { remaining.x = 0 } // direction change drops the old run instead of fighting it
        if remaining.y * y < 0 { remaining.y = 0 }
        remaining.x += x
        remaining.y += y
        self.flags = flags
        self.tau = tau
        if phase == .momentum { // like touching a trackpad during momentum: stop it, start a new gesture
            if !momentumPending { post(momentum: .end) }
            phase = .idle
        }
        if phase == .idle {
            phase = .gesture
            beganPending = true
        }
        guard timer == nil else { return }
        lastFrame = now
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { ScrollEngine.shared.step() }
        }
        RunLoop.main.add(t, forMode: .common) // .common keeps it running during menu/scroll tracking
        timer = t
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - lastFrame, 0.05)
        lastFrame = now

        if phase == .gesture, now - lastTick > Self.gestureHold {
            if !beganPending { post(scroll: .ended) }
            phase = .momentum
            momentumPending = true
        }

        let k = Self.decayFraction(dt: dt, tau: tau)
        let sx = Self.frameStep(remaining.x, k), sy = Self.frameStep(remaining.y, k)
        remaining.x -= sx
        remaining.y -= sy
        let ox = sx + carry.x, oy = sy + carry.y
        let ix = ox.rounded(.towardZero), iy = oy.rounded(.towardZero)
        carry = (ox - ix, oy - iy)

        if ix != 0 || iy != 0 {
            if phase == .gesture {
                post(dx: Int32(ix), dy: Int32(iy), scroll: beganPending ? .began : .changed)
                beganPending = false
            } else {
                post(dx: Int32(ix), dy: Int32(iy), momentum: momentumPending ? .begin : .continuous)
                momentumPending = false
            }
        }

        if phase == .momentum, remaining.x == 0, remaining.y == 0 {
            if !momentumPending { post(momentum: .end) }
            phase = .idle
            carry = (0, 0)
            timer?.invalidate()
            timer = nil
        }
    }

    private func post(dx: Int32 = 0, dy: Int32 = 0, scroll: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.flags = flags
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scroll?.rawValue ?? 0))
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        EventTap.post(e)
    }

    // Pinch (magnify) gestures cannot be synthesized with public CGEvent API, so zoom posts Cmd+= / Cmd+-,
    // which browsers, Preview, Finder and most document apps bind to zoom in/out.
    private func zoom(in zoomIn: Bool) {
        let key: CGKeyCode = zoomIn ? 24 : 27 // kVK_ANSI_Equal / kVK_ANSI_Minus
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            e.flags = .maskCommand
            EventTap.post(e)
        }
    }

    // MARK: - Pure math

    private static func direction(_ e: CGEvent, _ fixed: CGEventField, _ integer: CGEventField) -> Double {
        let v = e.getDoubleValueField(fixed)
        let d = v != 0 ? v : Double(e.getIntegerValueField(integer))
        return d > 0 ? 1 : d < 0 ? -1 : 0
    }

    /// A tick this long after the previous one counts as deliberate, slow scrolling.
    static let slowTickGap = 0.25

    static func acceleration(streak: Int) -> Double { min(1 + 0.3 * Double(streak), 5) }

    static func tickPixels(speed: ScrollSpeed, streak: Int, precise: Bool, swift: Bool) -> Double {
        let base: Double
        if precise {
            base = 12
        } else {
            let step: Double = switch speed { case .slow: 40; case .medium: 60; case .fast: 90 }
            base = step * acceleration(streak: streak)
        }
        return swift ? base * 3 : base
    }

    static func lines(forPixels px: Double) -> Int { max(1, Int((px / 20).rounded())) }

    /// Fraction of the remaining distance an exponential ease-out covers in `dt` seconds.
    static func decayFraction(dt: Double, tau: Double) -> Double { 1 - exp(-dt / tau) }

    /// Distance to deliver this frame; the last couple of pixels go at once to cut the infinite tail.
    static func frameStep(_ remaining: Double, _ k: Double) -> Double { abs(remaining) < 2 ? remaining : remaining * k }

    static func selfTest() {
        assert(acceleration(streak: 0) == 1)
        assert(acceleration(streak: 3) > acceleration(streak: 1))
        assert(acceleration(streak: 1000) == 5)
        assert(tickPixels(speed: .fast, streak: 0, precise: false, swift: false)
               > tickPixels(speed: .slow, streak: 0, precise: false, swift: false))
        assert(tickPixels(speed: .medium, streak: 10, precise: true, swift: false) == 12) // precise ignores acceleration
        assert(tickPixels(speed: .medium, streak: 0, precise: false, swift: true) == 180)
        assert(lines(forPixels: 12) == 1 && lines(forPixels: 60) == 3)
        assert(abs(decayFraction(dt: 0.06, tau: 0.06) - (1 - exp(-1))) < 1e-12)

        var r = -300.0, delivered = 0.0, frames = 0
        let k = decayFraction(dt: 1.0 / 120, tau: 0.06)
        while r != 0 && frames < 1000 {
            let s = frameStep(r, k)
            r -= s
            delivered += s
            frames += 1
        }
        assert(r == 0 && abs(delivered + 300) < 1e-9 && frames < 120) // finishes within a second, nothing lost
    }
}
