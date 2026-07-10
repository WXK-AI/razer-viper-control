import Foundation

/// Validates feature-report responses against the originating request.
/// Task 2 ships a CRC/status-only stub so correlation tests fail until Task 3.
public enum RazerResponseValidator {
    public static func validate(
        response: RazerReport,
        for request: RazerReport,
        allowingUnsupported: Bool
    ) throws -> CommandSendResult {
        let expectedCRC = RazerReport.calculateCRC(for: response.bytes)
        guard response.crc == expectedCRC else {
            throw RazerCommandError.invalidResponse("CRC mismatch.")
        }

        // Intentionally incomplete: no transaction / command correlation yet.
        _ = request

        switch response.responseStatus {
        case .successful:
            return .success(response)
        case .busy:
            throw RazerCommandError.deviceBusy
        case .notSupported:
            if allowingUnsupported {
                return .notSupported
            }
            throw RazerCommandError.unsupportedCommand
        case .timeout:
            throw RazerCommandError.timeout
        case .failure:
            throw RazerCommandError.invalidResponse("Command failed.")
        case .newCommand, .none:
            if response.status == 0x00 && response.commandClass == request.commandClass {
                throw RazerCommandError.blockedDeviceAccess("status 0x00 — no acknowledgement")
            }
            throw RazerCommandError.invalidResponse("status 0x\(String(response.status, radix: 16))")
        }
    }
}
