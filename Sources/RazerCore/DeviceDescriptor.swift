import Foundation

/// v1 device support for Razer Viper V3 HyperSpeed (USB 1532:00B8).
public enum DeviceDescriptor {
    public static let vendorID: UInt16 = 0x1532
    public static let productID: UInt16 = 0x00B8
    public static let deviceKey = "1532:00B8"
    public static let productName = "Razer Viper V3 HyperSpeed"

    public static let featureReportLength = 90
    public static let transactionID: UInt8 = 0x1F
    public static let responseWaitMilliseconds: UInt64 = 60
    public static let maxCommandRetries = 5

    public static let minDPI = 100
    public static let maxDPI = 30_000
    public static let maxDPIStages = 5

    public static let supportedPollingRates: [Int] = [125, 500, 1000]

    public static let primaryUsagePage: UInt32 = 1
    public static let primaryUsage: UInt32 = 2
}
