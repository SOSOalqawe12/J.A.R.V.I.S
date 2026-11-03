import SwiftUI
import LocalAuthentication

/// Optional Face ID / passcode lock.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isLocked: Bool
    private var authenticating = false

    init() {
        isLocked = AppSettings.shared.appLockEnabled
    }

    func lockIfNeeded() {
        if AppSettings.shared.appLockEnabled { isLocked = true }
    }

    func unlockIfNeeded() {
        guard isLocked else { return }
        authenticate()
    }

    func authenticate() {
        guard !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock JARVIS") { success, _ in
            Task { @MainActor in
                self.authenticating = false
                if success { withAnimation { self.isLocked = false } }
            }
        }
    }
}

struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            Theme.backgroundGradient
            VStack(spacing: 24) {
                CoreOrbView(mode: .idle, size: 140)
                Text("JARVIS is locked").font(.title3.weight(.semibold)).foregroundColor(.white)
                Button {
                    lock.authenticate()
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .onAppear { lock.authenticate() }
    }
}
