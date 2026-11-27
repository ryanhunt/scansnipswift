import Foundation

/// Bytes arriving on a stream, read in exact amounts with a timeout. Thread-safe; one reader at a time.
final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var closedError: ScannerError?
    private var waiter: (id: UInt64, count: Int, continuation: CheckedContinuation<[UInt8], Error>)?
    private var nextID: UInt64 = 0
    /// Timeouts or cancellations that fired before their reader registered.
    private var earlyFailures: [UInt64: Error] = [:]

    func append(_ data: some Sequence<UInt8>) {
        lock.lock()
        bytes.append(contentsOf: data)
        let resume = takeReady()
        lock.unlock()
        resume?()
    }

    /// No more bytes will come; a waiting or later read that cannot be met throws `error`.
    func close(_ error: ScannerError) {
        lock.lock()
        if closedError == nil { closedError = error }
        let resume = takeReady()
        lock.unlock()
        resume?()
    }

    func read(_ count: Int, timeout: Duration, operation: String) async throws -> [UInt8] {
        try Task.checkCancellation()
        let id = makeID()
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.fail(id, ScannerError.timedOut(operation))
        }
        defer {
            timer.cancel()
            forget(id)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let error = earlyFailures.removeValue(forKey: id) {
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                precondition(waiter == nil, "ByteBuffer has one reader at a time")
                waiter = (id, count, continuation)
                let resume = takeReady()
                lock.unlock()
                resume?()
            }
        } onCancel: {
            self.fail(id, CancellationError())
        }
    }

    private func makeID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func forget(_ id: UInt64) {
        lock.lock()
        earlyFailures[id] = nil
        lock.unlock()
    }

    /// Must hold the lock. Returns the resumption to run after unlocking, if the waiter can be answered.
    private func takeReady() -> (() -> Void)? {
        guard let current = waiter else { return nil }
        if bytes.count >= current.count {
            let out = Array(bytes.prefix(current.count))
            bytes.removeFirst(current.count)
            waiter = nil
            return { current.continuation.resume(returning: out) }
        }
        if let error = closedError {
            waiter = nil
            return { current.continuation.resume(throwing: error) }
        }
        return nil
    }

    private func fail(_ id: UInt64, _ error: Error) {
        lock.lock()
        var resume: (() -> Void)?
        if let current = waiter, current.id == id {
            waiter = nil
            resume = { current.continuation.resume(throwing: error) }
        } else if waiter == nil, id == nextID {
            // Only the newest read can still be about to register; an older id is already finished.
            earlyFailures[id] = error
        }
        lock.unlock()
        resume?()
    }
}

/// Datagrams arriving on a socket, read one at a time with a timeout. Thread-safe; one reader at a time.
final class MessageQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[UInt8]] = []
    private var closed = false
    private var waiter: (id: UInt64, continuation: CheckedContinuation<[UInt8]?, Error>)?
    private var nextID: UInt64 = 0
    /// Timeouts that fired before their reader registered.
    private var expired: Set<UInt64> = []

    func push(_ message: [UInt8]) {
        lock.lock()
        var resume: (() -> Void)?
        if let current = waiter {
            waiter = nil
            resume = { current.continuation.resume(returning: message) }
        } else {
            messages.append(message)
        }
        lock.unlock()
        resume?()
    }

    func close() {
        lock.lock()
        closed = true
        let current = waiter
        waiter = nil
        lock.unlock()
        current?.continuation.resume(throwing: ScannerError.connectionClosed("socket closed"))
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// The next message, nil on timeout; throws `ScannerError.connectionClosed` once the queue is closed and empty.
    func next(timeout: Duration) async throws -> [UInt8]? {
        let id = makeID()
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.expire(id)
        }
        defer {
            timer.cancel()
            forget(id)
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !messages.isEmpty {
                let message = messages.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: ScannerError.connectionClosed("socket closed"))
            } else if expired.remove(id) != nil {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                precondition(waiter == nil, "MessageQueue has one reader at a time")
                waiter = (id, continuation)
                lock.unlock()
            }
        }
    }

    private func makeID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func forget(_ id: UInt64) {
        lock.lock()
        expired.remove(id)
        lock.unlock()
    }

    private func expire(_ id: UInt64) {
        lock.lock()
        var resume: (() -> Void)?
        if let current = waiter, current.id == id {
            waiter = nil
            resume = { current.continuation.resume(returning: nil) }
        } else if waiter == nil, id == nextID {
            expired.insert(id)
        }
        lock.unlock()
        resume?()
    }
}

/// True exactly once, for callbacks that may fire more than once (connection states, timers).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// A value behind a lock, for state shared with callbacks.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
