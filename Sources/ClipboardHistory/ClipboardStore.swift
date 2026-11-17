import Foundation
import AppKit
import SQLite3
import ApplicationServices
import CoreGraphics

struct ClipboardItem: Identifiable, Equatable {
    let id: Int64
    let content: String
    let timestamp: Date
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Virtual keycode for the "C" key on ANSI layouts.
private let kVK_ANSI_C: Int64 = 8

private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }
    let store = Unmanaged<ClipboardStore>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in store.reenableTap() }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let modifiersOfInterest: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    let masked = flags.intersection(modifiersOfInterest)
    let isPlainCmdC = keyCode == kVK_ANSI_C && masked == .maskCommand

    if isPlainCmdC {
        // The destination app writes to the pasteboard AFTER handling the keydown.
        // Wait briefly, then check for an actual pasteboard update.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Task { @MainActor in store.handleCopyEvent() }
        }
    }

    return Unmanaged.passUnretained(event)
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    /// True when the keyboard event tap is installed and Accessibility is granted.
    /// Drives the menu-bar warning icon and the in-popover banner, so a lost
    /// permission is visible instead of silently killing capture.
    @Published private(set) var captureActive: Bool = false

    private var db: OpaquePointer?
    private var lastChangeCount: Int
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?

    init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        openDatabase()
        createTableIfNeeded()
        loadItems()
        requestAccessibilityPermission()
        installEventTap()
        startPermissionMonitor()
    }

    // MARK: - Database

    private var databaseURL: URL {
        let fm = FileManager.default
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("ClipboardHistory", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("history.sqlite")
    }

    private func openDatabase() {
        let path = databaseURL.path
        if sqlite3_open(path, &db) != SQLITE_OK {
            NSLog("ClipboardHistory: failed to open db at \(path)")
        }
    }

    private func createTableIfNeeded() {
        let sql = """
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL
            );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func loadItems() {
        var stmt: OpaquePointer?
        let sql = "SELECT id, content, timestamp FROM clipboard_items ORDER BY id DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var results: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let contentCStr = sqlite3_column_text(stmt, 1)
            let content = contentCStr.map { String(cString: $0) } ?? ""
            let ts = sqlite3_column_double(stmt, 2)
            results.append(ClipboardItem(
                id: id,
                content: content,
                timestamp: Date(timeIntervalSince1970: ts)
            ))
        }
        items = results
    }

    private func insert(content: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO clipboard_items (content, timestamp) VALUES (?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = Date()
        sqlite3_bind_text(stmt, 1, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        if sqlite3_step(stmt) == SQLITE_DONE {
            let id = sqlite3_last_insert_rowid(db)
            items.insert(
                ClipboardItem(id: id, content: content, timestamp: now),
                at: 0
            )
        }
    }

    // MARK: - Event tap

    private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    private func installEventTap() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            NSLog("ClipboardHistory: event tap creation failed. Grant Accessibility permission in System Settings → Privacy & Security → Accessibility.")
            captureActive = false
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        captureActive = true
        NSLog("ClipboardHistory: event tap installed.")
        return true
    }

    /// Polls Accessibility trust so the UI reflects reality: installs the tap
    /// once permission is granted, and flips `captureActive` back off if the
    /// permission is later revoked. Replaces the old silent 3s retry loop.
    private func startPermissionMonitor() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCaptureState() }
        }
    }

    private func refreshCaptureState() {
        let trusted = AXIsProcessTrusted()
        if trusted && eventTap == nil {
            installEventTap()
        }
        captureActive = trusted && eventTap != nil
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate func reenableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handleCopyEvent() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let str = pb.string(forType: .string), !str.isEmpty else { return }
        if items.first?.content == str { return }

        // Never persist anything that looks like a secret.
        if SecretFilter.skipReason(pasteboard: pb, text: str) != nil {
            return
        }
        insert(content: str)
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.content, forType: .string)
        lastChangeCount = pb.changeCount
    }
}
