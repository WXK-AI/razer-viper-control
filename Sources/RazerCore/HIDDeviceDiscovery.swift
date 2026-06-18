import Foundation
import IOKit.hid

public struct DiscoveredHIDInterface: Identifiable, Sendable {
    public let id: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let productName: String
    public let manufacturer: String
    public let primaryUsagePage: UInt32
    public let primaryUsage: UInt32
    public let maxFeatureReportSize: Int
    public let transport: String
    public let isTargetControlInterface: Bool

    public var summary: String {
        let marker = isTargetControlInterface ? " [control]" : ""
        return String(
            format: "%04X:%04X %@ usage %u:%u feature %dB transport %@%@",
            vendorID,
            productID,
            productName,
            primaryUsagePage,
            primaryUsage,
            maxFeatureReportSize,
            transport,
            marker
        )
    }
}

public enum HIDDiscoveryError: Error, LocalizedError {
    case managerCreationFailed
    case managerOpenFailed

    public var errorDescription: String? {
        switch self {
        case .managerCreationFailed:
            return "Failed to create IOHIDManager."
        case .managerOpenFailed:
            return "Failed to open IOHIDManager. Grant Input Monitoring permission in System Settings > Privacy & Security."
        }
    }
}

public final class HIDDeviceDiscovery {
    public init() {}

    public func listRazerInterfaces() throws -> [DiscoveredHIDInterface] {
        let manager = try makeManager()
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        return deviceSet
            .compactMap { describe(device: $0) }
            .filter { $0.vendorID == DeviceDescriptor.vendorID }
            .sorted { $0.summary < $1.summary }
    }

    public func findControlDevice() throws -> IOHIDDevice? {
        let manager = try makeManager()
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        let candidates = deviceSet
            .compactMap { device -> (IOHIDDevice, DiscoveredHIDInterface)? in
                guard let info = describe(device: device), info.isTargetControlInterface else { return nil }
                return (device, info)
            }
            .filter { $0.1.productID == DeviceDescriptor.productID }

        return candidates.first?.0
    }

    private func makeManager() throws -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: DeviceDescriptor.vendorID,
            kIOHIDProductIDKey: DeviceDescriptor.productID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDDiscoveryError.managerOpenFailed
        }

        return manager
    }

    private func describe(device: IOHIDDevice) -> DiscoveredHIDInterface? {
        let vendorID = UInt16(property(device, key: kIOHIDVendorIDKey) ?? 0)
        let productID = UInt16(property(device, key: kIOHIDProductIDKey) ?? 0)
        let usagePage = property(device, key: kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = property(device, key: kIOHIDPrimaryUsageKey) ?? 0
        let featureSize = property(device, key: kIOHIDMaxFeatureReportSizeKey) ?? 0
        let product = stringProperty(device, key: kIOHIDProductKey) ?? "Unknown"
        let manufacturer = stringProperty(device, key: kIOHIDManufacturerKey) ?? "Unknown"
        let transport = stringProperty(device, key: kIOHIDTransportKey) ?? "unknown"
        let locationID = property(device, key: kIOHIDLocationIDKey) ?? 0

        let isTarget = usagePage == DeviceDescriptor.primaryUsagePage
            && usage == DeviceDescriptor.primaryUsage
            && featureSize >= DeviceDescriptor.featureReportLength

        return DiscoveredHIDInterface(
            id: String(format: "%04X:%04X:%08X", vendorID, productID, locationID),
            vendorID: vendorID,
            productID: productID,
            productName: product,
            manufacturer: manufacturer,
            primaryUsagePage: usagePage,
            primaryUsage: usage,
            maxFeatureReportSize: Int(featureSize),
            transport: transport,
            isTargetControlInterface: isTarget
        )
    }

    private func property(_ device: IOHIDDevice, key: String) -> UInt32? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.uint32Value
    }

    private func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
