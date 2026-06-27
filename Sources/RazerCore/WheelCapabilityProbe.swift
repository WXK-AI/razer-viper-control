import Foundation

public enum WheelCapabilityProbe {
    public struct ProbeReport: Equatable, Sendable {
        public var capability: WheelHardwareCapability
        public var errors: [String]

        public init(capability: WheelHardwareCapability, errors: [String] = []) {
            self.capability = capability
            self.errors = errors
        }

        public var summary: String {
            var lines = [
                "scroll mode: \(capability.scrollMode.displayName)",
                "acceleration: \(capability.acceleration.displayName)",
                "smart reel: \(capability.smartReel.displayName)"
            ]
            if !errors.isEmpty {
                lines.append("errors:")
                lines.append(contentsOf: errors.map { " - \($0)" })
            }
            return lines.joined(separator: "\n")
        }
    }

    public static func summary(
        probeReport: ProbeReport,
        readback: RazerCommandClient.WheelHardwareReadback
    ) -> String {
        var lines = probeReport.summary.split(separator: "\n").map(String.init)
        if probeReport.capability.scrollMode == .supported,
           let mode = readback.settings.scrollMode {
            lines.append("readback scroll mode: \(mode.displayName)")
        }
        if probeReport.capability.acceleration == .supported,
           let enabled = readback.settings.accelerationEnabled {
            lines.append("readback acceleration: \(enabled ? "on" : "off")")
        }
        if probeReport.capability.smartReel == .supported,
           let enabled = readback.settings.smartReelEnabled {
            lines.append("readback smart reel: \(enabled ? "on" : "off")")
        }
        for error in readback.errors {
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }

    public static func probe(client: RazerCommandClient) -> ProbeReport {
        var errors: [String] = []
        let scrollMode = probeFeature("scroll mode", client.probeScrollMode, errors: &errors)
        let acceleration = probeFeature("acceleration", client.probeScrollAcceleration, errors: &errors)
        let smartReel = probeFeature("smart reel", client.probeScrollSmartReel, errors: &errors)
        return ProbeReport(
            capability: WheelHardwareCapability(
                scrollMode: scrollMode,
                acceleration: acceleration,
                smartReel: smartReel
            ),
            errors: errors
        )
    }

    public static func capability(from result: CommandSendResult) -> CapabilityResult {
        switch result {
        case .success:
            return .supported
        case .notSupported:
            return .notSupported
        }
    }

    public static func capability(from result: Result<CommandSendResult, Error>) -> CapabilityResult {
        switch result {
        case let .success(sendResult):
            return capability(from: sendResult)
        case .failure:
            return .unknown
        }
    }

    private static func probeFeature(
        _ label: String,
        _ operation: () throws -> CommandSendResult,
        errors: inout [String]
    ) -> CapabilityResult {
        do {
            return capability(from: try operation())
        } catch {
            errors.append("\(label): \(error.localizedDescription)")
            return .unknown
        }
    }
}
