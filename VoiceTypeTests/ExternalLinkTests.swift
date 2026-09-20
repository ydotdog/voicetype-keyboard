import Foundation
import Testing
@testable import VoiceType

@MainActor
struct ExternalLinkTests {
    @Test func outsideLinksCannotStartMicrophone() throws {
        let state = AppState()
        state.handleIncomingURL(try #require(URL(string: "voicetype://keyboard?autostart=1")))
        #expect(state.keyboardMicRequestID != nil)
        #expect(!state.consumeKeyboardMicAutoStart())
        state.handleIncomingURL(try #require(URL(string: "voicetype://record?autostart=1")))
        #expect(state.keyboardMicRequestID != nil)
        #expect(!state.consumeKeyboardMicAutoStart())
    }

    @Test func legacyRecordLinkReturnsHomeWithoutReusingAutoStart() throws {
        let state = AppState()
        state.presentKeyboardMic(autoStart: true)
        let previousRequest = state.keyboardMicRequestID
        state.handleIncomingURL(try #require(URL(string: "voicetype://record?autostart=1")))
        #expect(state.keyboardMicRequestID != nil)
        #expect(state.keyboardMicRequestID != previousRequest)
        #expect(!state.consumeKeyboardMicAutoStart())
    }

    @Test func unrelatedURLDoesNotOpenMicrophoneControls() throws {
        let state = AppState()
        state.handleIncomingURL(try #require(URL(string: "https://record?autostart=1")))
        #expect(state.keyboardMicRequestID == nil)
        #expect(state.keyboardSetupRequestID == nil)
    }

    @Test func keyboardActivationIsSingleUseAcrossAppStateInstances() throws {
        try withActivationStore { store in
            let url = try #require(store.makeURL())
            let state = AppState(activationStore: store)
            state.handleIncomingURL(url)
            #expect(state.hasPendingKeyboardMicAutoStart)
            #expect(state.consumeKeyboardMicAutoStart())
            #expect(!state.consumeKeyboardMicAutoStart())
            let relaunched = AppState(activationStore: store)
            relaunched.handleIncomingURL(url)
            #expect(!relaunched.hasPendingKeyboardMicAutoStart)
        }
    }

    @Test func duplicateSystemDeliveryDoesNotCancelAnUnconsumedKeyboardRequest() throws {
        try withActivationStore { store in
            let url = try #require(store.makeURL())
            let state = AppState(activationStore: store)
            state.handleIncomingURL(url)
            let firstID = state.keyboardMicRequestID
            state.handleIncomingURL(url)
            #expect(state.keyboardMicRequestID == firstID)
            #expect(state.consumeKeyboardMicAutoStart())
            state.handleIncomingURL(url)
            #expect(!state.consumeKeyboardMicAutoStart())
        }
    }

    @Test func pendingKeyboardActivationExpiresWhileWaitingForSignIn() throws {
        try withActivationStore { store in
            var clock = ProcessInfo.processInfo.systemUptime
            let url = try #require(store.makeURL(uptime: clock))
            let state = AppState(activationStore: store, uptime: { clock })
            state.handleIncomingURL(url)
            clock += 119
            #expect(state.hasPendingKeyboardMicAutoStart)
            clock += 1
            #expect(!state.hasPendingKeyboardMicAutoStart)
            #expect(!state.consumeKeyboardMicAutoStart())
            clock -= 120
            #expect(!state.hasPendingKeyboardMicAutoStart)
        }
    }

    @Test func genericAndSetupLinksCancelAnUnconsumedActivation() throws {
        try withActivationStore { store in
            let state = AppState(activationStore: store)
            for route in ["keyboard?autostart=1", "record?autostart=1", "keyboard-setup", "unknown"] {
                state.handleIncomingURL(try #require(store.makeURL()))
                #expect(state.hasPendingKeyboardMicAutoStart)
                state.handleIncomingURL(try #require(URL(string: "voicetype://\(route)")))
                #expect(!state.consumeKeyboardMicAutoStart())
            }
        }
    }

    @Test func expiredAndFutureActivationTokensCannotStartTheMicrophone() throws {
        try withActivationStore { store in
            let now = Date()
            let url = try #require(store.makeURL(now: now, uptime: 100))
            #expect(!store.consume(url, now: now.addingTimeInterval(90), uptime: 190))
            let future = try #require(store.makeURL(now: now, uptime: 200))
            #expect(!store.consume(future, now: now, uptime: 199))
            let clockRollback = try #require(store.makeURL(now: now, uptime: 200))
            #expect(!store.consume(clockRollback, now: now.addingTimeInterval(-60), uptime: 201))
        }
    }

    @Test func unrelatedOrMalformedTokensDoNotConsumeTheRealKeyboardRequest() throws {
        try withActivationStore { store in
            let valid = try #require(store.makeURL())
            let token = try #require(URLComponents(url: valid, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
            for value in [
                "voicetype://keyboard?activation=\(UUID().uuidString)",
                "voicetype://keyboard?activation=../../request",
                "voicetype://record?activation=\(token)",
                "voicetype://keyboard?activation=\(token)&activation=\(token)",
                "voicetype://keyboard?activation=\(token)#fragment"
            ] {
                #expect(!store.consume(try #require(URL(string: value))))
            }
            #expect(store.consume(valid))
        }
    }

    @Test func cancellingAPressNeedsNoActionAndRevocationRemovesTheCapability() throws {
        try withActivationStore { store in
            let url = try #require(store.makeURL())
            let state = AppState(activationStore: store)
            // Issuing the Link is not itself a microphone request. Only its
            // actual URL delivery can activate, regardless of input method.
            #expect(!state.hasPendingKeyboardMicAutoStart)
            store.revoke(url)
            state.handleIncomingURL(url)
            #expect(!state.consumeKeyboardMicAutoStart())
        }
    }

    @Test func rotatingTheVisibleLinkKeepsThePreviousInFlightURLValid() throws {
        try withActivationStore { store in
            let now = Date()
            let pressed = try #require(store.makeURL(now: now, uptime: 100))
            let replacement = try #require(store.makeURL(now: now.addingTimeInterval(30), uptime: 130))
            #expect(pressed != replacement)
            #expect(store.consume(pressed, now: now.addingTimeInterval(31), uptime: 131))
            #expect(!store.consume(pressed, now: now.addingTimeInterval(31), uptime: 131))
        }
    }

    @Test func concurrentReceiversCanClaimAnActivationOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardMicActivationStore(directoryURL: directory)
        let url = try #require(store.makeURL())
        let claimedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 { group.addTask { store.consume(url) } }
            var successes = 0
            for await claimed in group where claimed { successes += 1 }
            return successes
        }
        #expect(claimedCount == 1)
    }

    private func withActivationStore(body: (KeyboardMicActivationStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(KeyboardMicActivationStore(directoryURL: directory))
    }
}
