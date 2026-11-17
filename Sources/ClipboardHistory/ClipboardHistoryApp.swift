import SwiftUI
import AppKit

@main
struct ClipboardHistoryApp: App {
    @StateObject private var store = ClipboardStore()
    @StateObject private var gate = AuthGate()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
                .environmentObject(gate)
        } label: {
            // Warning triangle when capture is off (Accessibility missing) so
            // the failure is visible in the menu bar instead of silent.
            Image(systemName: store.captureActive ? "doc.on.clipboard" : "exclamationmark.triangle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
