import Foundation
import Testing
@testable import VoiceType

@Suite(.serialized)
@MainActor
struct PurchaseSyncTests {
    @Test func concurrentChecksForSameSessionWaitForOneCheck() async throws {
        let coordinator = PurchaseSyncCoordinator()
        let session = UUID()
        let check = PausedPurchaseCheck()
        let first = Task { await coordinator.run(sessionID: session) { await check.run() } }
        try await check.waitUntilStarted()
        var secondFinished = false
        let second = Task {
            await coordinator.run(sessionID: session) { await check.run() }
            secondFinished = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(check.starts == 1)
        #expect(!secondFinished)
        check.finish()
        await first.value
        await second.value
        #expect(secondFinished)
    }

    @Test func newAccountStartsImmediatelyAndOldCompletionCannotClearItsCheck() async throws {
        let coordinator = PurchaseSyncCoordinator()
        let previous = PausedPurchaseCheck()
        let current = PausedPurchaseCheck()
        let currentSession = UUID()
        let first = Task { await coordinator.run(sessionID: UUID()) { await previous.run() } }
        try await previous.waitUntilStarted()
        let second = Task { await coordinator.run(sessionID: currentSession) { await current.run() } }
        try await current.waitUntilStarted()
        previous.finish()
        await first.value
        #expect(previous.wasCancelled)
        let joined = Task { await coordinator.run(sessionID: currentSession) { await current.run() } }
        for _ in 0..<20 { await Task.yield() }
        #expect(current.starts == 1)
        current.finish()
        await second.value
        await joined.value
        #expect(!current.wasCancelled)
    }

    @Test func checkingPurchasesWhileSignedOutDoesNotReportSuccess() async {
        let account = AccountStore()
        account.signOut()
        let store = StoreKitService()
        await store.checkPurchases(account: account)
        #expect(store.errorMessage == "Sign in before checking purchases.")
        #expect(store.statusMessage == nil)
    }
}

@MainActor
private final class PausedPurchaseCheck {
    var starts = 0
    var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        starts += 1
        await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled
    }

    func waitUntilStarted() async throws {
        for _ in 0..<1_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        try #require(continuation != nil)
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
