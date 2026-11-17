import SwiftUI
import AppKit
import ApplicationServices

@main
struct MouseUpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = SettingsStore.shared

    var body: some Scene {
        MenuBarExtra("Mouse Up", systemImage: "computermouse", isInserted: Binding(
            get: { store.settings.showMenuBarIcon },
            // SwiftUI writes this binding on every render; assigning unchanged values re-publishes and loops forever.
            set: { if $0 != store.settings.showMenuBarIcon { store.settings.showMenuBarIcon = $0 } })) {
            Toggle("Enabled", isOn: $store.settings.enabled)
            Divider()
            Button("Open App") { SettingsWindow.show() }
            Button("Quit Mouse Up") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ScrollEngine.selfTest()
        ButtonEngine.selfTest()
        #endif
        debugLog("launch: trusted=\(AXIsProcessTrusted()) bundle=\(Bundle.main.bundlePath)")
        if !(AXIsProcessTrusted() && EventTap.shared.start()) { Permissions.begin() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return true
    }
}

/// AppKit-managed window: SwiftUI's `Settings` scene cannot be opened reliably from an
/// accessory app on macOS 14+ (no `openSettings` from the delegate, `showSettingsWindow:` was removed).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    // While the window is open the app is a regular app (Dock icon, Cmd-Tab), so clicking
    // elsewhere only sends it behind other windows instead of leaving it unreachable.
    static func show() {
        if window == nil {
            let w = makeWindow("Mouse Up", SettingsView())
            // Size the content before centering; makeWindow centers while the hosting view is still empty.
            w.contentView?.layoutSubtreeIfNeeded()
            w.setContentSize(w.contentView?.fittingSize ?? w.frame.size)
            if !w.setFrameUsingName("MainWindow") { w.center() }
            w.setFrameAutosaveName("MainWindow")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        present(window)
    }
}

@MainActor
func makeWindow(_ title: String, _ view: some View) -> NSWindow {
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.title = title
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.center()
    return window
}

@MainActor
func present(_ window: NSWindow?) {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
}
