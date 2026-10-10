import Foundation

/// A deterministic random generator (SplitMix64) so a failing property case can be replayed from its seed.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    public mutating func bytes(count: Int, excluding excluded: Set<UInt8> = []) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            let byte = UInt8.random(in: .min ... .max, using: &self)
            if !excluded.contains(byte) {
                result.append(byte)
            }
        }
        return result
    }
}

/// Runs `body` for `cases` seeds and reports the failing seed through the test's own expectations.
public func forEachSeed(_ cases: Int = 500, base: UInt64 = 0x5EED, _ body: (UInt64, inout SeededGenerator) throws -> Void) rethrows {
    for index in 0..<UInt64(cases) {
        let seed = base &+ index
        var generator = SeededGenerator(seed: seed)
        try body(seed, &generator)
    }
}

extension Data {
    public init(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
