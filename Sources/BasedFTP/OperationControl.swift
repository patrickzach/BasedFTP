import Foundation
import Darwin

// Shared operation lifetime; process-backed transports can attach their worker.
private final class WeakControl {
    weak var value: OperationControl?
    init(_ value: OperationControl) { self.value = value }
}
final class OperationControl: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [UUID: WeakControl] = [:]
    private let id = UUID()
    init() {
        Self.registryLock.lock(); Self.registry[id] = WeakControl(self); Self.registryLock.unlock()
    }
    static func cancelAll() {
        registryLock.lock(); let controls = registry.values.compactMap(\.value); registryLock.unlock()
        controls.forEach { $0.cancel() }
    }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var paused = false
    private var activity = Date()
    private var timer: DispatchSourceTimer?
    func attach(_ value: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        process = value; activity = Date()
        if paused { kill(value.processIdentifier, SIGSTOP) }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkTimeout() }; timer.resume(); self.timer = timer
    }
    func touch() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }; activity = Date()
    }
    // Native transports cooperate here on their worker thread; the UI never waits.
    func checkpoint() throws {
        while true {
            lock.lock(); let stopped = cancelled; let suspended = paused; lock.unlock()
            if stopped { throw CancellationError() }
            if !suspended { try touch(); return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; paused = false; let p = process; lock.unlock()
        if let p, p.isRunning { kill(p.processIdentifier, SIGCONT); kill(p.processIdentifier, SIGTERM) }
    }
    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; activity = Date(); let p = process; lock.unlock()
        if let p, p.isRunning { kill(p.processIdentifier, value ? SIGSTOP : SIGCONT) }
    }
    private func checkTimeout() {
        lock.lock(); let expired = !paused && Date().timeIntervalSince(activity) > 60; lock.unlock()
        if expired { cancel() }
    }
    func detach() { lock.lock(); timer?.cancel(); timer = nil; process = nil; lock.unlock() }
    deinit { timer?.cancel(); Self.registryLock.lock(); Self.registry.removeValue(forKey: id); Self.registryLock.unlock() }
}

