import Foundation

/// Thread-safe bridge from a remapper event tap onto `InputCaptureSession`.
///
/// Records without requiring the main actor so button/scroll bursts do not create
/// one `Task` (or main-queue hop) per input event.
///
/// `record`, `clear`, and `disableAndClear` share one lock so an in-flight record
/// cannot append after disable/clear has emptied the buffer.
public final class InputCaptureDiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var session: InputCaptureSession?

    public init() {}

    public func update(enabled: Bool, session: InputCaptureSession) {
        lock.lock()
        self.enabled = enabled
        self.session = session
        lock.unlock()
    }

    public func record(
        control: PhysicalControl?,
        disposition: InputCaptureSession.Disposition,
        detail: String = ""
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, let session else { return }
        session.recordRemapObservation(control: control, disposition: disposition, detail: detail)
    }

    /// Clears the attached session while excluding concurrent `record` calls.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        session?.clear()
    }

    /// Disables recording and clears the attached session as one critical section.
    public func disableAndClear() {
        lock.lock()
        enabled = false
        session?.clear()
        lock.unlock()
    }
}
