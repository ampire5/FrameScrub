import CFFmpeg
import CoreMedia
import CoreVideo

/// Copies FFmpeg colour metadata onto a pixel buffer so Core Image interprets it correctly.
/// Unspecified values fall back to BT.709 for HD and BT.601 for SD.
enum ColorAttachments {
    static func apply(from frame: UnsafePointer<AVFrame>, to pb: CVPixelBuffer) -> DynamicRange {
        let f = frame.pointee
        return apply(values(primaries: f.color_primaries, transfer: f.color_trc, space: f.colorspace,
                            height: f.height), to: pb)
    }

    /// For decoders that do not go through `AVFrame`: the stream's declared colour.
    static func apply(from parameters: UnsafePointer<AVCodecParameters>, to pb: CVPixelBuffer) -> DynamicRange {
        apply(values(parameters), to: pb)
    }

    /// The same values as format-description extensions.
    static func formatExtensions(_ parameters: UnsafePointer<AVCodecParameters>) -> [CFString: Any] {
        let v = values(parameters)
        return [kCVImageBufferColorPrimariesKey: v.primaries, kCVImageBufferTransferFunctionKey: v.transfer,
                kCVImageBufferYCbCrMatrixKey: v.matrix,
                kCMFormatDescriptionExtension_FullRangeVideo: parameters.pointee.color_range == AVCOL_RANGE_JPEG]
    }

    private typealias Values = (primaries: CFString, transfer: CFString, matrix: CFString, range: DynamicRange)

    private static func values(_ parameters: UnsafePointer<AVCodecParameters>) -> Values {
        let p = parameters.pointee
        return values(primaries: p.color_primaries, transfer: p.color_trc, space: p.color_space, height: p.height)
    }

    private static func apply(_ v: Values, to pb: CVPixelBuffer) -> DynamicRange {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, v.primaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, v.transfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, v.matrix, .shouldPropagate)
        return v.range
    }

    private static func values(primaries p: AVColorPrimaries, transfer trc: AVColorTransferCharacteristic,
                               space: AVColorSpace, height: Int32) -> Values {
        let hd = height > 576

        let primaries: CFString
        switch p {
        case AVCOL_PRI_BT2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: primaries = kCVImageBufferColorPrimaries_P3_D65
        case AVCOL_PRI_BT470BG: primaries = kCVImageBufferColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: primaries = kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT709: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        default: primaries = hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        }

        let transfer: CFString
        let range: DynamicRange
        switch trc {
        case AVCOL_TRC_ARIB_STD_B67:
            transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            range = .hlg
        case AVCOL_TRC_SMPTE2084:
            transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            range = .pq
        default:
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2
            range = .sdr
        }

        let matrix: CFString
        switch space {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_BT709: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        default: matrix = hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }
        return (primaries, transfer, matrix, range)
    }
}
