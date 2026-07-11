import Foundation
import SystemExtensions

/// Activation lifecycle for the embedded Razer Viper HID DriverKit extension.
enum DriverActivationState: String, Equatable {
    case unknown
    case submitting
    case needsUserApproval
    case pendingReboot
    case activating
    case activated
    case deactivating
    case deactivated
    case failed

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .submitting: return "Submitting"
        case .needsUserApproval: return "Needs approval in System Settings"
        case .pendingReboot: return "Pending reboot"
        case .activating: return "Activating"
        case .activated: return "Activated"
        case .deactivating: return "Deactivating"
        case .deactivated: return "Deactivated"
        case .failed: return "Failed"
        }
    }
}

/// Host-side activator for `com.razermenubar.RazerViperHIDDriver`.
@MainActor
final class SystemExtensionManager: NSObject, ObservableObject {
    static let driverBundleIdentifier = "com.razermenubar.RazerViperHIDDriver"

    @Published private(set) var state: DriverActivationState = .unknown
    @Published private(set) var statusMessage: String = "Driver status has not been queried yet."
    @Published private(set) var lastErrorDescription: String?

    /// Invoked on the main actor whenever activation state or messages change.
    var onStateChange: (() -> Void)?

    private var activeRequest: OSSystemExtensionRequest?

    private func publishChange() {
        refreshStatusMessage()
        onStateChange?()
    }

    func refreshStatusMessage() {
        switch state {
        case .activated:
            statusMessage = "Driver extension is activated. Physical ownership proofs are still required before remapping."
        case .needsUserApproval:
            statusMessage = "Approve the system extension in System Settings → Privacy & Security, then retry."
        case .pendingReboot:
            statusMessage = "System extension change will complete after reboot."
        case .failed:
            statusMessage = lastErrorDescription ?? "Driver activation failed."
        case .deactivated:
            statusMessage = "Driver extension is deactivated."
        default:
            statusMessage = "Driver activation state: \(state.displayName)."
        }
    }

    func activate() {
        guard activeRequest == nil else { return }
        lastErrorDescription = nil
        state = .submitting
        publishChange()

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.driverBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        activeRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        guard activeRequest == nil else { return }
        lastErrorDescription = nil
        state = .deactivating
        publishChange()

        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.driverBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        activeRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .needsUserApproval
            self.publishChange()
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            self.activeRequest = nil
            switch result {
            case .completed:
                if self.state == .deactivating {
                    self.state = .deactivated
                } else {
                    self.state = .activated
                }
            case .willCompleteAfterReboot:
                self.state = .pendingReboot
                self.publishChange()
                return
            @unknown default:
                self.state = .failed
                self.lastErrorDescription = "Unknown system extension result."
            }
            self.publishChange()
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.activeRequest = nil
            self.state = .failed
            self.lastErrorDescription = error.localizedDescription
            self.publishChange()
        }
    }
}
