import Foundation

/// Immutable table of supported devices, keyed by `(vendorID, productID)`.
///
/// A value, not a singleton. `HIDDeviceDiscovery` and `DeviceSession` are the only
/// types that hold one; nothing downstream of discovery looks a device up, which is
/// what keeps `builtIn` from becoming ambient state. Intentionally IOKit-free:
/// matching dictionaries are assembled by the two call sites that need them, because
/// their key sets differ.
public struct DeviceRegistry: Sendable, Equatable {
    public let models: [MouseModel]

    private struct Key: Hashable {
        let vendorID: UInt16
        let productID: UInt16
    }

    private let modelsByKey: [Key: MouseModel]

    public init(models: [MouseModel]) {
        self.models = models
        modelsByKey = Dictionary(
            models.map { (Key(vendorID: $0.vendorID, productID: $0.productID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func model(vendorID: UInt16, productID: UInt16) -> MouseModel? {
        modelsByKey[Key(vendorID: vendorID, productID: productID)]
    }

    public func model(forDeviceKey deviceKey: String) -> MouseModel? {
        models.first { $0.deviceKey == deviceKey }
    }

    public func contains(vendorID: UInt16) -> Bool {
        models.contains { $0.vendorID == vendorID }
    }

    /// The table this build ships.
    public static let builtIn = DeviceRegistry(models: [.viperV3HyperSpeed])
}
