import Foundation
import Testing
@testable import VoiceType

struct WeakObserverRegistryTests {
    private final class Observer: Sendable {
        let id: Int
        init(_ id: Int) { self.id = id }
    }

    @Test func registryDoesNotKeepOwnerAliveAndLateCallbackGetsNil() {
        let registry = WeakObserverRegistry<Observer>()
        let token = registry.makeToken()
        var owner: Observer? = Observer(1)
        weak var lifetime = owner
        registry.register(owner!, token: token)
        #expect(registry.lookup(token) === owner)
        owner = nil
        #expect(lifetime == nil)
        #expect(registry.lookup(token) == nil)
        registry.remove(token)
        #expect(registry.lookup(token) == nil)
    }

    @Test func resolvedCallbackHoldsOwnerSafelyAcrossDeregistration() {
        let registry = WeakObserverRegistry<Observer>()
        let token = registry.makeToken()
        var owner: Observer? = Observer(1)
        registry.register(owner!, token: token)
        let callbackOwner = registry.lookup(token)
        registry.remove(token)
        owner = nil
        #expect(callbackOwner?.id == 1)
        #expect(registry.lookup(token) == nil)
        let replacement = Observer(2)
        let replacementToken = registry.makeToken()
        registry.register(replacement, token: replacementToken)
        #expect(replacementToken != token)
        #expect(registry.lookup(token) == nil)
        #expect(registry.lookup(replacementToken) === replacement)
    }

    @Test func concurrentRegistrationLookupAndRemovalStayIsolated() async {
        let registry = WeakObserverRegistry<Observer>()
        let valid = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let owner = Observer(index)
                    let token = registry.makeToken()
                    registry.register(owner, token: token)
                    let resolved = registry.lookup(token)
                    registry.remove(token)
                    return resolved === owner && registry.lookup(token) == nil
                }
            }
            var results = true
            for await result in group { results = results && result }
            return results
        }
        #expect(valid)
    }
}
