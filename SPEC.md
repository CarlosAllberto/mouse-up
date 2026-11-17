# Mouse Up — spec

Free, open-source macOS utility that makes third-party mice feel as good as a trackpad.
Written from scratch. **No code from Mac Mouse Fix may be read, copied or adapted.**
Implement from this spec, Apple documentation and general knowledge only.

Target: macOS 13+, Swift 6 toolchain (language mode 5), SwiftUI + AppKit, no third-party dependencies.
Single app process (no separate helper). Menu bar item + settings window.
Build with `xcodegen` from `project.yml`, then `xcodebuild`.

## Architecture (files in `Sources/`)

| File | Owner | Role |
|---|---|---|
| `Settings.swift` | core (done) | `Settings` Codable model + `SettingsStore` (UserDefaults, ObservableObject) |
| `EventTap.swift` | core (done) | One `CGEventTap` (session, head insert). Routes events to `ScrollEngine` and `ButtonEngine`. Tags synthetic events so they are not re-processed. |
| `ScrollEngine.swift` | agent A | Smooth scrolling, modifiers, reverse |
| `ButtonEngine.swift`, `Actions.swift` | agent B | Button remapping, click/double/hold/drag, system actions |
| `App.swift`, `SettingsView.swift`, `Permissions.swift` | agent C | App entry, menu bar, settings UI, Accessibility permission, launch at login |

Contracts every agent must respect:

```swift
// EventTap calls these on the tap thread (the main run loop). Return nil to swallow the event.
final class ScrollEngine { static let shared: ScrollEngine; func handle(_ event: CGEvent) -> CGEvent? }
final class ButtonEngine { static let shared: ButtonEngine; func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? }
// Read current settings: SettingsStore.shared.settings (main thread).
// Post synthetic events with EventTap.post(_:) so they carry the synthetic tag.
// Check trackpad/continuous events with event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 and leave them untouched.
```

## Features

### Scrolling (agent A)
- Smooth scrolling: each wheel tick starts/extends an animation; output continuous pixel scroll events (`CGEvent(scrollWheelEvent2Source:units:.pixel...)`) with proper scroll phases (began/changed/ended) and momentum phase so apps behave like trackpad scrolling. Drive with `CVDisplayLink` or a 120 Hz timer.
- Smoothness: off / regular / high (animation duration and inertia).
- Speed: slow / medium / fast; plus acceleration — fast consecutive ticks scroll further.
- Reverse direction (independent from system "natural" setting), vertical and horizontal separately.
- Modifiers while scrolling (each assignable to a modifier key in settings, defaults in parentheses):
  - Precise scroll (Option): small, non-accelerated steps.
  - Horizontal scroll (Shift): vertical wheel scrolls horizontally.
  - Zoom (Command): emits pinch-zoom (prefer posting `Cmd +`/`Cmd -` fallback only if needed; document choice).
  - Swift/fast scroll (Control): multiplies distance.
- Only for mouse wheels, never touch trackpad or Magic Mouse continuous events.

### Buttons (agent B)
- Handles middle (2), back (3), forward (4) and extra buttons (5+).
- Per button, independent triggers: click, double click, hold (long press ~350 ms), click-and-drag.
- Assignable actions: none (pass through), middle click, back, forward, Mission Control, App Exposé, Show Desktop, Launchpad, Spaces left, Spaces right, Look Up (dictionary), Smart Zoom, keyboard shortcut (key code + modifiers), open app/URL is NOT required.
- Drag actions: "Mission Control & Spaces" (drag up = Mission Control, down = App Exposé, left/right = switch Space) and "Scroll & navigate" (drag moves content like a trackpad scroll) and "none".
- Defaults: button 3 → click Back; button 4 → click Forward; middle → click middle click, drag left native (Figma etc. pan with middle-drag).
- When a button has no hold/double/drag assigned, act on mouse-down immediately for zero latency; otherwise wait the needed time.
- System actions: use public means where they exist (`open -a "Mission Control"`, NSWorkspace, synthetic keys); for Spaces/Mission Control prefer synthesized `ctrl+arrow`/`ctrl+up`/`ctrl+down` key events and document the limitation that they follow the user's keyboard shortcuts.
- Back/forward: synthesize `cmd+[` / `cmd+]` (document limitation).

### App (agent C)
- Menu bar extra (`MenuBarExtra`) with: Enabled toggle, Settings…, Quit. App runs as accessory (LSUIElement).
- Settings window, tabs: General (enable, launch at login via `SMAppService.mainApp`, show menu bar icon), Buttons (list of buttons with trigger → action pickers; "Add button" by pressing it), Scrolling (all scrolling options above), About (version, MIT license, GitHub link placeholder).
- Accessibility permission onboarding: if `AXIsProcessTrusted()` is false, show a window explaining why, button to open System Settings (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`), poll every 1 s, start `EventTap` once granted.
- If the menu bar icon is hidden, reopening the app (launch again) shows the settings window.
