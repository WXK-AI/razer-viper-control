import XCTest
@testable import RazerCore

final class HIDInterfaceSelectionTests: XCTestCase {
    private func interface(
        transport: String,
        locationID: UInt32?,
        selectionIdentity: UInt64,
        productName: String = "Razer Viper V3 HyperSpeed"
    ) -> DiscoveredHIDInterface {
        DiscoveredHIDInterface(
            id: DiscoveredHIDInterface.makeID(
                vendorID: DeviceDescriptor.vendorID,
                productID: DeviceDescriptor.productID,
                selectionIdentity: selectionIdentity
            ),
            vendorID: DeviceDescriptor.vendorID,
            productID: DeviceDescriptor.productID,
            productName: productName,
            manufacturer: "Razer",
            primaryUsagePage: DeviceDescriptor.primaryUsagePage,
            primaryUsage: DeviceDescriptor.primaryUsage,
            maxFeatureReportSize: DeviceDescriptor.featureReportLength,
            transport: transport,
            locationID: locationID,
            isTargetControlInterface: true,
            selectionIdentity: selectionIdentity
        )
    }

    private func assertSelects(
        _ expected: DiscoveredHIDInterface,
        from interfaces: [DiscoveredHIDInterface],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for permutation in permutations(of: interfaces) {
            let selected = HIDDeviceDiscovery.selectControlInterface(from: permutation)
            XCTAssertEqual(
                selected?.selectionIdentity,
                expected.selectionIdentity,
                "value selection failed for order \(permutation.map(\.selectionIdentity))",
                file: file,
                line: line
            )
            XCTAssertEqual(
                selected?.id,
                expected.id,
                file: file,
                line: line
            )

            guard let index = HIDDeviceDiscovery.selectControlInterfaceIndex(from: permutation) else {
                XCTFail("expected index for non-empty candidates", file: file, line: line)
                return
            }
            XCTAssertEqual(
                permutation[index].selectionIdentity,
                expected.selectionIdentity,
                "index mapping must return the exact selected candidate",
                file: file,
                line: line
            )
            XCTAssertEqual(
                permutation[index].id,
                expected.id,
                file: file,
                line: line
            )
        }
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        var results: [[T]] = []
        func permute(_ prefix: [T], _ rest: [T]) {
            if rest.isEmpty {
                results.append(prefix)
                return
            }
            for index in rest.indices {
                var nextRest = rest
                let value = nextRest.remove(at: index)
                permute(prefix + [value], nextRest)
            }
        }
        permute([], values)
        return results
    }

    func testPublicIDUsesSelectionIdentityNotLocation() {
        let withNilLocation = interface(transport: "USB", locationID: nil, selectionIdentity: 0xABC)
        let withZeroLocation = interface(transport: "USB", locationID: 0, selectionIdentity: 0xABC)

        XCTAssertEqual(withNilLocation.id, "1532:00B8:0000000000000ABC")
        XCTAssertEqual(withZeroLocation.id, withNilLocation.id)
        XCTAssertNotEqual(withNilLocation.locationID, withZeroLocation.locationID)
        XCTAssertNil(withNilLocation.locationID)
        XCTAssertEqual(withZeroLocation.locationID, 0)
        XCTAssertFalse(withNilLocation.summary.contains("reg "))
        XCTAssertTrue(withNilLocation.summary.contains("loc nil"))
        XCTAssertTrue(withZeroLocation.summary.contains("loc 00000000"))
    }

    func testPrefersUSBOverBluetoothEvenWhenBluetoothHasLowerLocationID() {
        let bluetooth = interface(transport: "Bluetooth", locationID: 0x0001, selectionIdentity: 1)
        let usb = interface(transport: "USB", locationID: 0x1000, selectionIdentity: 2)
        assertSelects(usb, from: [bluetooth, usb])
    }

    func testAmongPreferredTransportsChoosesLowestLocationID() {
        let high = interface(transport: "USB", locationID: 0x2000, selectionIdentity: 10)
        let low = interface(transport: "USB", locationID: 0x0100, selectionIdentity: 99)
        assertSelects(low, from: [high, low])
    }

    func testUnknownTransportLosesToUSB() {
        let unknown = interface(transport: "unknown", locationID: 0x0001, selectionIdentity: 3)
        let usb = interface(transport: "USB", locationID: 0x9999, selectionIdentity: 4)
        assertSelects(usb, from: [unknown, usb])
    }

    func testMissingLocationLosesToActualLocationZero() {
        let missing = interface(transport: "USB", locationID: nil, selectionIdentity: 50)
        let zero = interface(transport: "USB", locationID: 0, selectionIdentity: 51)
        assertSelects(zero, from: [missing, zero])
    }

    func testMissingLocationLosesToKnownLowerLocation() {
        let missing = interface(transport: "USB", locationID: nil, selectionIdentity: 7)
        let known = interface(transport: "USB", locationID: 0x50, selectionIdentity: 8)
        assertSelects(known, from: [missing, known])
    }

    func testCollidingVendorProductLocationUsesSelectionIdentity() {
        let higherIdentity = interface(transport: "USB", locationID: 0x100, selectionIdentity: 0x200)
        let lowerIdentity = interface(transport: "USB", locationID: 0x100, selectionIdentity: 0x100)
        assertSelects(lowerIdentity, from: [higherIdentity, lowerIdentity])
    }

    func testCollidingLocationIndexMappingIsNotUndoneByNonUniqueDisplayFields() {
        let first = interface(transport: "USB", locationID: 0x100, selectionIdentity: 0x200)
        let second = interface(transport: "USB", locationID: 0x100, selectionIdentity: 0x100)
        let order = [first, second]

        let index = HIDDeviceDiscovery.selectControlInterfaceIndex(from: order)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(order[index!].selectionIdentity, second.selectionIdentity)

        let reversed = [second, first]
        let reversedIndex = HIDDeviceDiscovery.selectControlInterfaceIndex(from: reversed)
        XCTAssertEqual(reversedIndex, 0)
        XCTAssertEqual(reversed[reversedIndex!].selectionIdentity, second.selectionIdentity)

        XCTAssertEqual(first.locationID, second.locationID)
        XCTAssertNotEqual(first.selectionIdentity, second.selectionIdentity)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testThreeWayPermutationKeepsUSBLowestLocationThenLowestSelectionIdentity() {
        let bluetooth = interface(transport: "Bluetooth", locationID: 0x1, selectionIdentity: 1)
        let usbHighLoc = interface(transport: "USB", locationID: 0x20, selectionIdentity: 2)
        let usbLowLoc = interface(transport: "USB", locationID: 0x10, selectionIdentity: 3)
        assertSelects(usbLowLoc, from: [bluetooth, usbHighLoc, usbLowLoc])
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(HIDDeviceDiscovery.selectControlInterface(from: []))
        XCTAssertNil(HIDDeviceDiscovery.selectControlInterfaceIndex(from: []))
    }
}
