import Foundation

/// Thread-safe lifecycle generation shared by AppModel's main actor and HID
/// queue. A token authorizes work only while its generation remains awake.
public final class DeviceLifecycleGate: @unchecked Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var sleeping = false

    public init() {}

    public func currentAwakeToken() -> Token? {
        lock.lock()
        defer { lock.unlock() }
        guard !sleeping else { return nil }
        return Token(generation: generation)
    }

    public func transitionToSleep() {
        lock.lock()
        generation &+= 1
        sleeping = true
        lock.unlock()
    }

    @discardableResult
    public func transitionToWake() -> Token {
        lock.lock()
        generation &+= 1
        sleeping = false
        let token = Token(generation: generation)
        lock.unlock()
        return token
    }

    public func invalidateForRemoval() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    public func isCurrentAndAwake(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !sleeping && token.generation == generation
    }
}
