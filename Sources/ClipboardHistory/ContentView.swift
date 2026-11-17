import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ClipboardStore
    @EnvironmentObject var gate: AuthGate
    @State private var page: Int = 0
    @State private var selected: ClipboardItem?

    private let pageSize = 10

    private var totalPages: Int {
        max(1, Int(ceil(Double(store.items.count) / Double(pageSize))))
    }

    private var pagedItems: [ClipboardItem] {
        let start = page * pageSize
        let end = min(start + pageSize, store.items.count)
        guard start < end else { return [] }
        return Array(store.items[start..<end])
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.captureActive {
                permissionBanner
                Divider()
            }
            if gate.isUnlocked {
                header
                Divider()
                if let item = selected {
                    detail(item)
                } else {
                    list
                }
                Divider()
                footer
            } else {
                lockedView
            }
        }
        .frame(width: 400, height: 460)
        .onAppear { if !gate.isUnlocked { gate.unlock() } }
        .onChange(of: gate.isUnlocked) { unlocked in
            // Drop any open entry/page when the session expires.
            if !unlocked {
                selected = nil
                page = 0
            }
        }
    }

    private var lockedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Clipboard history is locked")
                .font(.headline)
            Text("Authenticate with Touch ID or your Mac password.\nAccess lasts 5 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = gate.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            Button("Unlock") { gate.unlock() }
                .disabled(gate.isAuthenticating)
                .keyboardShortcut(.defaultAction)
            Spacer()
            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clipboard capture is off")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Grant Accessibility permission so ⌘C can be recorded.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 8)
            Button("Open Settings") { store.openAccessibilitySettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange)
    }

    private var header: some View {
        HStack {
            Text(selected == nil ? "Clipboard History" : "Entry")
                .font(.headline)
            Spacer()
            if selected != nil {
                Button("Back") { selected = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        Group {
            if pagedItems.isEmpty {
                VStack {
                    Spacer()
                    Text("No clipboard history yet.\nCopy something to get started.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pagedItems) { item in
                            row(item)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: ClipboardItem) -> some View {
        Button {
            selected = item
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(displayText(item.content))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(relativeTime(item.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    store.copyToPasteboard(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                Text(item.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            if selected == nil {
                Button("Prev") { if page > 0 { page -= 1 } }
                    .disabled(page == 0)
                Spacer()
                Text("Page \(page + 1) of \(totalPages)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Next") { if page < totalPages - 1 { page += 1 } }
                    .disabled(page >= totalPages - 1)
            } else {
                Spacer()
            }
            Divider().frame(height: 16)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func displayText(_ s: String) -> String {
        let single = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if single.count <= 50 { return single }
        return String(single.prefix(50)) + "…"
    }

    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
