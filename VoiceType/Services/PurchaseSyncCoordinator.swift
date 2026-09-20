import Foundation

/// Joins checks for the same account and lets a new account start immediately.
/// A cancelled older check cannot clear the newer check's ownership.
@MainActor
final class PurchaseSyncCoordinator {
    private var active: (id: UUID, sessionID: UUID, task: Task<Void, Never>)?

    func run(sessionID: UUID, operation: @escaping @MainActor () async -> Void) async {
        if let active, active.sessionID == sessionID {
            await active.task.value
            return
        }
        active?.task.cancel()
        let id = UUID()
        let task = Task { await operation() }
        active = (id, sessionID, task)
        await task.value
        if active?.id == id { active = nil }
    }

    func cancel() {
        active?.task.cancel()
        active = nil
    }
}
