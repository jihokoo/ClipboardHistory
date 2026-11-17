import Foundation
import LocalAuthentication

/// Gates viewing the history behind Touch ID / the Mac login password.
/// Unlocking lasts `sessionLength`; after that the history locks again and the
/// next view requires re-authentication. Capture is unaffected by the lock.
///
/// Fails closed: if the device can't authenticate (e.g. no password set), the
/// history stays locked and the reason is shown.
@MainActor
final class AuthGate: ObservableObject {
    static let sessionLength: TimeInterval = 5 * 60

    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastError: String?

    private var lockTimer: Timer?

    func unlock() {
        guard !isUnlocked, !isAuthenticating else { return }

        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            lastError = policyError?.localizedDescription ?? "Authentication is unavailable on this Mac."
            return
        }

        isAuthenticating = true
        lastError = nil
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "view your clipboard history"
        ) { [weak self] success, error in
            let cancelled = (error as? LAError)?.code == .userCancel
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.markUnlocked()
                } else if !cancelled {
                    self.lastError = message ?? "Authentication failed."
                }
            }
        }
    }

    func lock() {
        lockTimer?.invalidate()
        lockTimer = nil
        isUnlocked = false
    }

    private func markUnlocked() {
        isUnlocked = true
        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionLength, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }
}
