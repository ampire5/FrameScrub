import Foundation

enum VideoCodecFamily { case h264, hevc }

/// Facts about the parameter sets of an avcC/hvcC record that packet parsing needs.
struct ParameterSets {
    let family: VideoCodecFamily
    /// Bytes of the big-endian length before every NAL unit of a packet (1–4).
    let nalLengthSize: Int
    let spsCount: Int
    let ppsCount: Int
    /// HEVC PPS facts by pps id: what the first slice header's layout depends on.
    let hevcPPS: [Int: (outputFlagPresent: Bool, extraSliceHeaderBits: Int, dependentSliceSegmentsEnabled: Bool)]

    /// nil when `extradata` is not an avcC/hvcC record (Annex B, too short, malformed).
    static func parse(extradata: Data, family: VideoCodecFamily) -> ParameterSets? {
        let bytes = [UInt8](extradata)
        guard bytes.first == 1 else { return nil }
        switch family {
        case .h264:
            guard bytes.count >= 7 else { return nil }
            var offset = 6
            let spsCount = Int(bytes[5] & 0x1f)
            guard skipEntries(spsCount, in: bytes, at: &offset), offset < bytes.count else { return nil }
            let ppsCount = Int(bytes[offset])
            offset += 1
            guard skipEntries(ppsCount, in: bytes, at: &offset) else { return nil }
            return ParameterSets(family: .h264, nalLengthSize: Int(bytes[4] & 3) + 1, spsCount: spsCount,
                                 ppsCount: ppsCount, hevcPPS: [:])
        case .hevc:
            guard bytes.count >= 23 else { return nil }
            var offset = 23
            var spsCount = 0, ppsCount = 0
            var pps: [Int: (outputFlagPresent: Bool, extraSliceHeaderBits: Int, dependentSliceSegmentsEnabled: Bool)] = [:]
            for _ in 0..<Int(bytes[22]) {
                guard offset + 3 <= bytes.count else { return nil }
                let type = Int(bytes[offset] & 0x3f)
                let count = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
                offset += 3
                for _ in 0..<count {
                    guard offset + 2 <= bytes.count else { return nil }
                    let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                    offset += 2
                    guard offset + length <= bytes.count else { return nil }
                    if type == 33 { spsCount += 1 }
                    if type == 34 {
                        ppsCount += 1
                        var reader = BitReader(bytes[offset..<offset + length].dropFirst(2))   // 2-byte NAL header
                        if let id = reader.readUE(), reader.readUE() != nil,
                           let dependent = reader.readBit(), let output = reader.readBit(),
                           let extra = reader.readBits(3) {
                            pps[id] = (output, extra, dependent)
                        }
                    }
                    offset += length
                }
            }
            return ParameterSets(family: .hevc, nalLengthSize: Int(bytes[21] & 3) + 1, spsCount: spsCount,
                                 ppsCount: ppsCount, hevcPPS: pps)
        }
    }

    private static func skipEntries(_ count: Int, in bytes: [UInt8], at offset: inout Int) -> Bool {
        for _ in 0..<count {
            guard offset + 2 <= bytes.count else { return false }
            offset += 2 + (Int(bytes[offset]) << 8 | Int(bytes[offset + 1]))
            guard offset <= bytes.count else { return false }
        }
        return true
    }
}

/// What the NAL headers of one access unit (a packet with length-prefixed NAL units) say about its picture.
struct AccessUnitInfo {
    /// False when every VCL NAL unit is a non-reference picture: nothing else refers to it.
    let isReference: Bool
    /// H.264 IDR, HEVC IRAP.
    let isRandomAccess: Bool
    /// HEVC RASL/RADL: decoded after the IRAP they precede.
    let isLeading: Bool
    /// "I", "P" or "B" from the first slice header, as FFmpeg reports it; nil when it could not be parsed.
    let pictureType: Character?

    static func parse(_ data: UnsafeBufferPointer<UInt8>, parameterSets: ParameterSets) -> AccessUnitInfo {
        let lengthSize = parameterSets.nalLengthSize
        let hevc = parameterSets.family == .hevc
        var offset = 0
        var sawVCL = false, reference = false, randomAccess = false, leading = false
        var pictureType: Character?
        while offset + lengthSize < data.count {
            var length = 0
            for i in 0..<lengthSize { length = length << 8 | Int(data[offset + i]) }
            let start = offset + lengthSize
            let end = min(start + length, data.count)
            offset = start + length
            guard length > 0 else { continue }
            let header = data[start]
            if hevc {
                let type = Int(header >> 1) & 0x3f
                guard type <= 31, end - start > 2 else { continue }
                if !sawVCL { pictureType = hevcPictureType(data[(start + 2)..<end], type: type, parameterSets) }
                sawVCL = true
                if type > 14 || type % 2 == 1 { reference = true }
                if (16...23).contains(type) { randomAccess = true }
                if (6...9).contains(type) { leading = true }
            } else {
                let type = Int(header & 0x1f)
                guard type == 1 || type == 5 else { continue }
                if !sawVCL { pictureType = h264PictureType(data[(start + 1)..<end]) }
                sawVCL = true
                if header >> 5 & 3 != 0 { reference = true }
                if type == 5 { randomAccess = true }
            }
        }
        return AccessUnitInfo(isReference: reference || !sawVCL, isRandomAccess: randomAccess, isLeading: leading,
                              pictureType: pictureType)
    }

    private static func h264PictureType(_ payload: Slice<UnsafeBufferPointer<UInt8>>) -> Character? {
        var reader = BitReader(payload)
        guard reader.readUE() != nil, let sliceType = reader.readUE() else { return nil }   // first_mb_in_slice
        switch sliceType % 5 {
        case 0, 3: return "P"
        case 1: return "B"
        default: return "I"
        }
    }

    private static func hevcPictureType(_ payload: Slice<UnsafeBufferPointer<UInt8>>, type: Int,
                                         _ sets: ParameterSets) -> Character? {
        var reader = BitReader(payload)
        guard reader.readBit() == true else { return nil }   // only the first slice segment has a known layout
        if (16...23).contains(type) { guard reader.readBit() != nil else { return nil } }   // no_output_of_prior_pics
        guard let ppsID = reader.readUE(), let pps = sets.hevcPPS[ppsID],
              reader.readBits(pps.extraSliceHeaderBits) != nil, let sliceType = reader.readUE() else { return nil }
        switch sliceType {
        case 0: return "B"
        case 1: return "P"
        case 2: return "I"
        default: return nil
        }
    }
}

/// Reads bits of an RBSP from NAL payload bytes, dropping emulation-prevention bytes (00 00 03).
private struct BitReader {
    private var bytes: [UInt8] = []
    private var position = 0

    init<C: Collection>(_ payload: C) where C.Element == UInt8 {
        var zeros = 0
        for byte in payload.prefix(64) {   // slice and PPS headers we read are short
            if zeros >= 2 && byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            bytes.append(byte)
        }
    }

    mutating func readBit() -> Bool? {
        guard position < bytes.count * 8 else { return nil }
        defer { position += 1 }
        return bytes[position / 8] >> (7 - position % 8) & 1 == 1
    }

    mutating func readBits(_ count: Int) -> Int? {
        var value = 0
        for _ in 0..<count {
            guard let bit = readBit() else { return nil }
            value = value << 1 | (bit ? 1 : 0)
        }
        return value
    }

    /// Unsigned Exp-Golomb.
    mutating func readUE() -> Int? {
        var zeros = 0
        while true {
            guard let bit = readBit() else { return nil }
            if bit { break }
            zeros += 1
            guard zeros < 32 else { return nil }
        }
        guard let rest = readBits(zeros) else { return nil }
        return (1 << zeros) - 1 + rest
    }
}
