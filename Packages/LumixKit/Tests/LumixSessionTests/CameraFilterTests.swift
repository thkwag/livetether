import Testing
@testable import LumixSession

@Suite("Camera filter")
struct CameraFilterTests {
    @Test("Only a USB Panasonic camera with an allowed product ID that accepts PTP commands is used")
    func acceptance() {
        let filter = CameraFilter()
        #expect(filter.accepts(vendorID: 0x04DA, productID: 0x2382, isUSB: true, acceptsPTPCommands: true))
        #expect(!filter.accepts(vendorID: 0x04DA, productID: 0x2374, isUSB: true, acceptsPTPCommands: true))
        #expect(!filter.accepts(vendorID: 0x04A9, productID: 0x2382, isUSB: true, acceptsPTPCommands: true))
        #expect(!filter.accepts(vendorID: 0x04DA, productID: 0x2382, isUSB: false, acceptsPTPCommands: true))
        #expect(!filter.accepts(vendorID: 0x04DA, productID: 0x2382, isUSB: true, acceptsPTPCommands: false))
    }

    @Test("A configured allowlist replaces the default product ID")
    func configuredAllowlist() {
        let filter = CameraFilter(productIDs: [0x2374])
        #expect(filter.accepts(vendorID: 0x04DA, productID: 0x2374, isUSB: true, acceptsPTPCommands: true))
        #expect(!filter.accepts(vendorID: 0x04DA, productID: 0x2382, isUSB: true, acceptsPTPCommands: true))
    }
}
