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

    @Test("Product ID lists parse from hexadecimal with or without 0x, separated by commas or spaces")
    func parsing() {
        #expect(CameraFilter.parseProductIDs("2382") == [0x2382])
        #expect(CameraFilter.parseProductIDs("2382, 0x2374") == [0x2382, 0x2374])
        #expect(CameraFilter.parseProductIDs(" 2382  2374 ") == [0x2382, 0x2374])
        #expect(CameraFilter.parseProductIDs("") == nil)
        #expect(CameraFilter.parseProductIDs("23G2") == nil)
        #expect(CameraFilter.parseProductIDs("12345") == nil)
        #expect(CameraFilter.parseProductIDs("2382,,") == [0x2382])
    }

    @Test("Formatting lists the IDs sorted, as four hexadecimal digits, and parses back")
    func formatting() {
        let ids: Set<Int> = [0x2382, 0x0F, 0x2374]
        #expect(CameraFilter.formatProductIDs(ids) == "000F, 2374, 2382")
        #expect(CameraFilter.parseProductIDs(CameraFilter.formatProductIDs(ids)) == ids)
    }
}
