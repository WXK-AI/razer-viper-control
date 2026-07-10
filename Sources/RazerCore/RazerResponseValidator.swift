import Foundation

/// Injectable transport for 90-byte Razer feature-report round trips.
public protocol RazerReportTransport: Sendable {
    func roundTrip(_ request: [UInt8]) throws -> [UInt8]
}

/// Validates feature-report responses against the originating request.
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

        guard response.transactionID == request.transactionID else {
            throw RazerCommandError.invalidResponse("transaction ID mismatch")
        }
        guard response.remainingPackets == 0 else {
            throw RazerCommandError.invalidResponse("remaining packets mismatch")
        }
        guard response.protocolType == request.protocolType else {
            throw RazerCommandError.invalidResponse("protocol type mismatch")
        }
        guard response.commandClass == request.commandClass else {
            throw RazerCommandError.invalidResponse("command class mismatch")
        }
        guard response.commandID == request.commandID else {
            throw RazerCommandError.invalidResponse("command ID mismatch")
        }
        try validateDataSize(response: response, for: request)

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

    /// Fixed responses require an exact `dataSize` match.
    /// Commands that may return a larger known payload can be listed here later with an explicit minimum.
    private static func validateDataSize(response: RazerReport, for request: RazerReport) throws {
        guard response.dataSize == request.dataSize else {
            throw RazerCommandError.invalidResponse("data size mismatch")
        }
    }
}
