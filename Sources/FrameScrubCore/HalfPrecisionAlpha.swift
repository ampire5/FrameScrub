import Accelerate
import Foundation

/// Converts IEEE binary16 alpha without Swift.Float16, which is unavailable on Intel Macs.
/// Scratch is bounded by the plane dimensions; vImage stays on the calling worker.
public enum HalfPrecisionAlpha {
    public static func bytes(from storage: UnsafeRawBufferPointer, width: Int, height: Int,
                             rowStride: Int, columnStride: Int) -> Data? {
        guard let values = floats(from: storage, width: width, height: height,
                                  rowStride: rowStride, columnStride: columnStride) else { return nil }
        var output = Data(count: values.count)
        output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for i in values.indices {
                let bounded: Float = max(Float(0), min(Float(1), values[i]))
                bytes[i] = UInt8(bounded * Float(255) + Float(0.5))
            }
        }
        return output
    }

    static func floats(from storage: UnsafeRawBufferPointer, width: Int, height: Int,
                       rowStride: Int, columnStride: Int) -> [Float]? {
        guard width > 0, height > 0, rowStride >= 0, columnStride >= 0,
              let base = storage.baseAddress else { return nil }
        let (count, countOverflow) = width.multipliedReportingOverflow(by: height)
        let (lastRow, rowOverflow) = (height - 1).multipliedReportingOverflow(by: rowStride)
        let (lastColumn, columnOverflow) = (width - 1).multipliedReportingOverflow(by: columnStride)
        let (lastIndex, indexOverflow) = lastRow.addingReportingOverflow(lastColumn)
        guard !countOverflow, !rowOverflow, !columnOverflow, !indexOverflow,
              count <= Int.max / MemoryLayout<Float>.stride,
              lastIndex < storage.count / MemoryLayout<UInt16>.stride else { return nil }
        var result = [Float](repeating: 0, count: count)
        func convert(_ source: UnsafeRawPointer, rowBytes: Int) -> Bool {
            result.withUnsafeMutableBytes { destination in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source),
                                          height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                var output = vImage_Buffer(data: destination.baseAddress!, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
                return vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
            }
        }
        if columnStride == 1, rowStride >= width {
            let sourceRowStride = height == 1 ? width : rowStride
            guard convert(base, rowBytes: sourceRowStride * MemoryLayout<UInt16>.stride) else { return nil }
        } else {
            // vImage has no column stride. Preserve transposed, padded and repeated samples.
            var packed = [UInt16](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * rowStride + x * columnStride) * MemoryLayout<UInt16>.stride
                    packed[y * width + x] = storage.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                }
            }
            let converted = packed.withUnsafeBytes { convert($0.baseAddress!, rowBytes: width * MemoryLayout<UInt16>.stride) }
            guard converted else { return nil }
        }
        return result
    }
}
