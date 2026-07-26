import Foundation
import IOKit
import IOKit.hid

public struct DiscoveredHIDInterface: Identifiable, Sendable, Equatable {
    public let id: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let productName: String
    public let manufacturer: String
    public let primaryUsagePage: UInt32
    public let primaryUsage: UInt32
    public let maxFeatureReportSize: Int
    public let transport: String
    /// Display / ranking location from `kIOHIDLocationIDKey`. Not used as device identity.
    /// `nil` means the property was absent (distinct from a reported `0`).
    public let locationID: UInt32?
    public let isTargetControlInterface: Bool
    /// Registry entry this interface resolved to, or `nil` when the product ID is unknown.
    public let model: MouseModel?

    /// Unique within a discovery pass for selection ordering/mapping.
    /// Prefers `IORegistryEntryGetRegistryEntryID` when available; otherwise a process-local fallback.
    let selectionIdentity: UInt64

    public var summary: String {
        let marker = isTargetControlInterface ? " [control]" : ""
        let locationText: String
        if let locationID {
            locationText = String(format: " loc %08X", locationID)
        } else {
            locationText = " loc nil"
        }
        return String(
            format: "%04X:%04X %@ usage %u:%u feature %dB transport %@%@%@",
            vendorID,
            productID,
            productName,
            primaryUsagePage,
            primaryUsage,
            maxFeatureReportSize,
            transport,
            locationText,
            marker
        )
    }

    /// Builds the public `id` from vendor/product + selection identity (not location).
    static func makeID(
        vendorID: UInt16,
        productID: UInt16,
        selectionIdentity: UInt64
    ) -> String {
        String(format: "%04X:%04X:%016llX", vendorID, productID, selectionIdentity)
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

/// Resolved control interface: the device handle plus the registry entry it matched.
public struct ResolvedControlDevice {
    public let device: IOHIDDevice
    public let model: MouseModel
    public let interface: DiscoveredHIDInterface
}

public final class HIDDeviceDiscovery {
    private let registry: DeviceRegistry

    public init(registry: DeviceRegistry) {
        self.registry = registry
    }

    public func listRazerInterfaces() throws -> [DiscoveredHIDInterface] {
        let manager = try makeManager()
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        return deviceSet
            .compactMap { describe(device: $0) }
            .filter { registry.contains(vendorID: $0.vendorID) }
            .sorted { $0.summary < $1.summary }
    }

    public func findControlDevice() throws -> ResolvedControlDevice? {
        let manager = try makeManager()
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        let candidates: [(IOHIDDevice, DiscoveredHIDInterface)] = deviceSet
            .compactMap { device -> (IOHIDDevice, DiscoveredHIDInterface)? in
                guard let info = describe(device: device), info.isTargetControlInterface else { return nil }
                return (device, info)
            }
            .filter { $0.1.model != nil }

        // Index into this candidate array — never remap via display location / non-unique fields.
        guard let index = Self.selectControlInterfaceIndex(from: candidates.map(\.1)) else {
            return nil
        }
        let (device, interface) = candidates[index]
        guard let model = interface.model else { return nil }
        return ResolvedControlDevice(device: device, model: model, interface: interface)
    }

    /// Deterministic pick among control-interface candidates (by value).
    static func selectControlInterface(from interfaces: [DiscoveredHIDInterface]) -> DiscoveredHIDInterface? {
        guard let index = selectControlInterfaceIndex(from: interfaces) else { return nil }
        return interfaces[index]
    }

    /// Preferred candidate index in `interfaces`. Callers map back with this index.
    static func selectControlInterfaceIndex(from interfaces: [DiscoveredHIDInterface]) -> Int? {
        guard !interfaces.isEmpty else { return nil }
        return interfaces.indices.min { lhs, rhs in
            isPreferredControlInterface(interfaces[lhs], before: interfaces[rhs])
        }
    }

    /// Total order: transport preference → known lowest location → selection identity → `id`.
    private static func isPreferredControlInterface(
        _ lhs: DiscoveredHIDInterface,
        before rhs: DiscoveredHIDInterface
    ) -> Bool {
        let leftRank = transportPreferenceRank(lhs.transport)
        let rightRank = transportPreferenceRank(rhs.transport)
        if leftRank != rightRank {
            return leftRank < rightRank
        }

        let leftLocation = lhs.locationID ?? .max
        let rightLocation = rhs.locationID ?? .max
        if leftLocation != rightLocation {
            return leftLocation < rightLocation
        }

        if lhs.selectionIdentity != rhs.selectionIdentity {
            return lhs.selectionIdentity < rhs.selectionIdentity
        }

        return lhs.id < rhs.id
    }

    /// Lower rank is preferred. USB/dongle beat unknown/other; Bluetooth is last.
    private static func transportPreferenceRank(_ transport: String) -> Int {
        let normalized = transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("usb") || normalized.contains("dongle") {
            return 0
        }
        if normalized.contains("bluetooth") {
            return 2
        }
        // Missing, "unknown", or unrecognized transports stay between USB and Bluetooth.
        return 1
    }

    private func makeManager() throws -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [[String: Any]] = registry.models.map { model in
            [
                kIOHIDVendorIDKey: model.vendorID,
                kIOHIDProductIDKey: model.productID
            ]
        }
        if matching.count == 1 {
            // Byte-identical to the pre-registry single-dictionary call.
            IOHIDManagerSetDeviceMatching(manager, matching[0] as CFDictionary)
        } else {
            IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        }
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
        let locationID = property(device, key: kIOHIDLocationIDKey)
        let selectionIdentity = Self.selectionIdentity(for: device)

        let model = registry.model(vendorID: vendorID, productID: productID)
        // Unrecognized interfaces stay listed for diagnostics; they just are not targets.
        let isTarget = model.map {
            usagePage == $0.primaryUsagePage
                && usage == $0.primaryUsage
                && featureSize >= UInt32($0.minimumFeatureReportSize)
        } ?? false

        return DiscoveredHIDInterface(
            id: DiscoveredHIDInterface.makeID(
                vendorID: vendorID,
                productID: productID,
                selectionIdentity: selectionIdentity
            ),
            vendorID: vendorID,
            productID: productID,
            productName: product,
            manufacturer: manufacturer,
            primaryUsagePage: usagePage,
            primaryUsage: usage,
            maxFeatureReportSize: Int(featureSize),
            transport: transport,
            locationID: locationID,
            isTargetControlInterface: isTarget,
            model: model,
            selectionIdentity: selectionIdentity
        )
    }

    /// Selection identity for one discovery pass: registry-entry ID when
    /// `IORegistryEntryGetRegistryEntryID` succeeds; otherwise a high-bit-tagged
    /// process-local surrogate from the in-process `IOHIDDevice` object identity
    /// so candidates stay distinct and totally ordered (not stable across launches).
    private static func selectionIdentity(for device: IOHIDDevice) -> UInt64 {
        let service = IOHIDDeviceGetService(device)
        var entryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
            return entryID
        }
        let pointerValue = UInt64(UInt(bitPattern: ObjectIdentifier(device)))
        return 0x8000_0000_0000_0000 | (pointerValue & 0x7FFF_FFFF_FFFF_FFFF)
    }

    private func property(_ device: IOHIDDevice, key: String) -> UInt32? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.uint32Value
    }

    private func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
