import Foundation

/// CF notifications do not retain their opaque observer pointers. Tokens are
/// never dereferenced, and lookup takes a strong reference while holding a lock.
/// A callback racing removal therefore gets either a live object or nil.
final class WeakObserverRegistry<Value: AnyObject>: @unchecked Sendable {
    private final class Entry {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }

    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var entries: [UInt: Entry] = [:]

    func makeToken() -> UInt {
        lock.lock()
        defer { lock.unlock() }
        // Never recycle a token: a queued old callback cannot address a newly
        // allocated observer that happens to occupy the same memory address.
        precondition(nextToken < UInt.max)
        defer { nextToken += 1 }
        return nextToken
    }

    func register(_ value: Value, token: UInt) {
        lock.lock()
        defer { lock.unlock() }
        entries[token] = Entry(value)
    }

    func lookup(_ token: UInt) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]?.value
    }

    func remove(_ token: UInt) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: token)
    }
}
