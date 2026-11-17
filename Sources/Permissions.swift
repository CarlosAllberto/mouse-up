import SwiftUI
import AppKit
import ApplicationServices

/// Accessibility onboarding: shows a window and polls until the app is trusted, then starts the tap.
@MainActor
enum Permissions {
    private static var window: NSWindow?
    private static var timer: Timer?
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func begin() {
        if window == nil { window = makeWindow("Mouse Up", OnboardingView()) }
        present(window)
        guard timer == nil else { return }
        // Literal value of kAXTrustedCheckOptionPrompt (the global is not concurrency-safe in Swift 6).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // .common mode: a default-mode timer never fired while the onboarding window was up.
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func poll() {
        // Tap creation can fail for a moment right after access is granted, so keep polling until it starts.
        let trusted = AXIsProcessTrusted()
        let started = trusted && EventTap.shared.start()
        debugLog("permission poll: trusted=\(trusted) tapStarted=\(started)")
        guard started else { return }
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
    }
}

private struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
            Text("Allow Accessibility Access").font(.title2.bold())
            Text("Mouse Up needs Accessibility access to read your mouse buttons and scroll wheel and turn them into smooth scrolling and actions. Nothing is recorded or sent anywhere.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open System Settings, then turn on Mouse Up under Privacy & Security › Accessibility.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { NSWorkspace.shared.open(Permissions.settingsURL) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            HStack {
                // macOS sometimes keeps the old trust state for a running process; a relaunch picks up the new grant.
                Button("Relaunch") { Permissions.relaunch() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for permission…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 400)
    }
}

/// Appends to ~/Library/Logs/MouseUp.log so permission problems can be diagnosed without Console access.
func debugLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MouseUp.log")
    let line = Data("\(Date()) \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(line); try? handle.close()
    } else {
        try? line.write(to: url)
    }
}
