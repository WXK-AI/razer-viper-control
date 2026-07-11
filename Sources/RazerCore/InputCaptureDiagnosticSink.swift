import Foundation

/// Thread-safe bridge from a remapper event tap onto `InputCaptureSession`.
///
/// Records without requiring the main actor so button/scroll bursts do not create
/// one `Task` (or main-queue hop) per input event.
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
        guard enabled, let session else {
            lock.unlock()
            return
        }
        let target = session
        lock.unlock()
        target.recordRemapObservation(control: control, disposition: disposition, detail: detail)
    }
}
