import CoreML
import CryptoKit
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct HalfPrecisionAlphaTests {
    @Test func clampsAndRoundsHalfSamples() throws {
        let bits: [UInt16] = [0xbc00, 0, 1, 0x3400, 0x3800, 0x3c00, 0x4000, 0xfc00, 0x7c00, 0x7e00]
        let bytes = try bits.withUnsafeBytes {
            try #require(HalfPrecisionAlpha.bytes(from: $0, width: bits.count, height: 1,
                                                  rowStride: bits.count, columnStride: 1))
        }
        #expect(Array(bytes) == [0, 0, 0, 64, 128, 255, 255, 0, 255, 255])
    }

    @Test func preservesPaddedTransposedAndRepeatedStrides() throws {
        let cases: [(bits: [UInt16], row: Int, column: Int, expected: [UInt8])] = [
            ([0, 0x3800, 0x3c00, 0xdead, 0x3400, 0x3c00, 0, 0xbeef], 4, 1, [0, 128, 255, 64, 255, 0]),
            ([0, 0x3400, 0x3800, 0x3c00, 0x3c00, 0], 1, 2, [0, 128, 255, 64, 255, 0]),
            ([0x3800], 0, 0, [128, 128, 128, 128, 128, 128])
        ]
        for item in cases {
            let bytes = try item.bits.withUnsafeBytes {
                try #require(HalfPrecisionAlpha.bytes(from: $0, width: 3, height: 2,
                                                      rowStride: item.row, columnStride: item.column))
            }
            #expect(Array(bytes) == item.expected)
        }
    }

    @Test func readsCoreMLFloat16StorageThroughRawAccess() throws {
        let plane = MLMultiArray(shape: [1, 1, 2, 3], dataType: .float16, strides: [16, 16, 8, 2])
        let bits: [UInt16] = [0, 0x3800, 0x3c00, 0x3400, 0x3c00, 0]
        plane.withUnsafeMutableBytes { bytes, strides in
            for y in 0..<2 {
                for x in 0..<3 {
                    bytes.storeBytes(of: bits[y * 3 + x], toByteOffset: (y * strides[2] + x * strides[3]) * 2, as: UInt16.self)
                }
            }
        }
        let bytes = try plane.withUnsafeBytes {
            try #require(HalfPrecisionAlpha.bytes(from: $0, width: 3, height: 2, rowStride: 8, columnStride: 2))
        }
        #expect(Array(bytes) == [0, 128, 255, 64, 255, 0])
    }

    @Test func rejectsStorageTooShortForItsStrides() {
        let bits: [UInt16] = [0, 0]
        bits.withUnsafeBytes {
            #expect(HalfPrecisionAlpha.bytes(from: $0, width: 2, height: 2, rowStride: 3, columnStride: 1) == nil)
            #expect(HalfPrecisionAlpha.bytes(from: $0, width: Int.max, height: 2, rowStride: 0, columnStride: 0) == nil)
        }
    }

    /// SHA-256 of all 65,536 ordered outputs from the original native-arm Float16 clamp/round expression.
    /// The digest lets Intel verify the same exhaustive oracle without a Float16 numeric API or fixture file.
    @Test func everyHalfBitPatternMatchesTheNativeQuantizationDigest() throws {
        let bits = (0...UInt16.max).map { UInt16($0) }
        let bytes = try bits.withUnsafeBytes {
            try #require(HalfPrecisionAlpha.bytes(from: $0, width: 256, height: 256, rowStride: 256, columnStride: 1))
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "e4941ba773dfb43adc14ae4f58275e276a23f860c8dbaa2ec23d0989d884af7c")
    }

    #if arch(arm64)
    @Test func everyHalfBitPatternMatchesNativeConversionAndQuantization() throws {
        let bits = (0...UInt16.max).map { UInt16($0) }
        let converted = try bits.withUnsafeBytes {
            try #require(HalfPrecisionAlpha.floats(from: $0, width: 256, height: 256, rowStride: 256, columnStride: 1))
        }
        let bytes = try bits.withUnsafeBytes {
            try #require(HalfPrecisionAlpha.bytes(from: $0, width: 256, height: 256, rowStride: 256, columnStride: 1))
        }
        for i in bits.indices {
            let native = Float(Float16(bitPattern: bits[i]))
            if native.isNaN { #expect(converted[i].isNaN) }
            else { #expect(converted[i].bitPattern == native.bitPattern) }
            let expected = UInt8(max(Float(0), min(Float(1), native)) * Float(255) + Float(0.5))
            #expect(bytes[i] == expected)
        }
    }
    #endif
}
