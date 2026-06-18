import Foundation

public enum WheelCapabilityProbe {
    public static func probe(client: RazerCommandClient) -> WheelHardwareCapability {
        let scrollMode = capability(from: (try? client.probeScrollMode()) ?? .notSupported)
        let acceleration = capability(from: (try? client.probeScrollAcceleration()) ?? .notSupported)
        let smartReel = capability(from: (try? client.probeScrollSmartReel()) ?? .notSupported)
        return WheelHardwareCapability(
            scrollMode: scrollMode,
            acceleration: acceleration,
            smartReel: smartReel
        )
    }

    private static func capability(from result: CommandSendResult) -> CapabilityResult {
        switch result {
        case .success:
            return .supported
        case .notSupported:
            return .notSupported
        }
    }
}
