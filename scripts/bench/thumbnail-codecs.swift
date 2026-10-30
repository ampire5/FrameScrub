// swift scripts/bench/thumbnail-codecs.swift /path/to/image1 /path/to/image2 ...
// Shared image-codec benchmark for photo/video thumbnails. Sources are read at 1280 px maximum; no original is changed.
import CoreGraphics
import Foundation
import ImageIO

func cpu() -> Double {
    var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
    return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6
}
func raster(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> (CGImage, [UInt8])? {
    let w = width ?? image.width, h = height ?? image.height
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    let made: CGImage? = bytes.withUnsafeMutableBytes { memory in
        guard let c = CGContext(data: memory.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }
    return made.map { ($0, bytes) }
}
#if EXTRA_CODECS
func extra(_ type: String) -> (Int32, Int32)? {
    switch type {
    case "libwebp": (1,4)
    case "libjxl-e3": (2,3)
    case "libjxl-e7": (2,7)
    case "libjpeg-turbo": (3,0)
    case "libjpeg-turbo-444": (3,1)
    case "libavif-aom-s6": (4,6)
    case "libavif-aom-s8": (4,8)
    default: nil
    }
}
#endif
func encode(_ image: CGImage, type: String, quality: Double, rgba: [UInt8]) -> Data? {
#if EXTRA_CODECS
    if let (codec, effort) = extra(type) {
        var output: UnsafeMutablePointer<UInt8>?, length = 0
        let ok = rgba.withUnsafeBufferPointer { bench_encode(codec, $0.baseAddress, Int32(image.width), Int32(image.height),
                                                           quality, effort, &output, &length) }
        guard ok != 0, let output else { return nil }
        defer { bench_free(output) }
        return Data(bytes: output, count: length)
    }
#endif
    let bytes = NSMutableData()
    guard let d = CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(d) ? bytes as Data : nil
}
func decode(_ bytes: Data, type: String) -> (CGImage, [UInt8])? {
#if EXTRA_CODECS
    if let (codec, _) = extra(type) {
        var output: UnsafeMutablePointer<UInt8>?, w: Int32 = 0, h: Int32 = 0
        let ok = bytes.withUnsafeBytes { bench_decode(codec, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
                                                      &output, &w, &h) }
        guard ok != 0, let output, w > 0, h > 0 else { return nil }
        defer { bench_free(output) }
        let data = Data(bytes: output, count: Int(w*h*4))
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w)*4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return raster(image)
    }
#endif
    guard let s = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
    return raster(image)
}
func decodeCell(_ bytes: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true,
              kCGImageSourceThumbnailMaxPixelSize:128, kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { return nil }
    return raster(image)?.0
}
func quality(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> (Double, Double) {
    var error = 0.0, ssim = 0.0, windows = 0
    for p in stride(from: 0, to: a.count, by: 4) {
        for c in 0..<3 { let d = Double(a[p+c]) - Double(b[p+c]); error += d*d }
    }
    // Non-overlapping 8x8 luminance windows; no resizing before measuring distortion.
    for y in stride(from: 0, to: height-7, by: 8) {
        for x in stride(from: 0, to: width-7, by: 8) {
            var sx=0.0, sy=0.0, xx=0.0, yy=0.0, xy=0.0
            for j in 0..<8 { for i in 0..<8 {
                let p = ((y+j)*width+x+i)*4
                let u = 0.2126*Double(a[p])+0.7152*Double(a[p+1])+0.0722*Double(a[p+2])
                let v = 0.2126*Double(b[p])+0.7152*Double(b[p+1])+0.0722*Double(b[p+2])
                sx += u; sy += v; xx += u*u; yy += v*v; xy += u*v
            }}
            let mx=sx/64, my=sy/64
            let vx=max(0,(xx-64*mx*mx)/63), vy=max(0,(yy-64*my*my)/63), cv=(xy-64*mx*my)/63
            ssim += ((2*mx*my+6.5025)*(2*cv+58.5225))/((mx*mx+my*my+6.5025)*(vx+vy+58.5225))
            windows += 1
        }
    }
    let mse = error / Double(width*height*3)
    return (mse == 0 ? 99 : 10*log10(65025/mse), ssim/Double(max(1,windows)))
}
func run() {
    let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
    var types = ["public.jpeg", "public.heic", "public.avif"].filter(supported.contains)
#if EXTRA_CODECS
    types += ["libjpeg-turbo", "libjpeg-turbo-444", "libwebp", "libjxl-e3", "libjxl-e7", "libavif-aom-s6", "libavif-aom-s8"]
#endif
    print("sample,side,codec,q,bytes,encodeWallMs,encodeCPUMs,decodeWallMs,decodeCPUMs,PSNR,SSIM,cellImageIOWallMs,cellPSNR,cellSSIM")
    let environment = ProcessInfo.processInfo.environment
    let sizes = environment["THUMB_BENCH_SIZES"]?.split(separator: ",").compactMap { Int($0) } ?? [256,480,1280]
    let qualities = environment["THUMB_BENCH_QUALITIES"]?.split(separator: ",").compactMap { Double($0) } ?? [0.5,0.65,0.8,0.9,0.95,0.98]
    for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
        guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL, nil),
              let original = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:1280] as CFDictionary) else { continue }
        for side in sizes {
            let scale = min(1, Double(side)/Double(max(original.width,original.height)))
            guard let (source, reference) = raster(original, width:max(8,Int(Double(original.width)*scale)),
                                                   height:max(8,Int(Double(original.height)*scale))) else { continue }
            for type in types { for q in qualities {
                autoreleasepool {
                    let start=Date(), c0=cpu()
                    guard let bytes=encode(source,type:type,quality:q,rgba:reference) else { return }
                    let encCPU=cpu()-c0, encWall=Date().timeIntervalSince(start)*1000
                    let d0=Date(), dc=cpu()
                    guard let (_, decoded)=decode(bytes,type:type) else { return }
                    let decCPU=cpu()-dc, decWall=Date().timeIntervalSince(d0)*1000
                    let (psnr,ssim)=quality(reference,decoded,width:source.width,height:source.height)
                    let cellStart=Date()
                    let cell = decodeCell(bytes)
                    let cellWall = cell == nil ? -1 : Date().timeIntervalSince(cellStart)*1000
                    var cellPSNR = -1.0, cellSSIM = -1.0
                    if let cell, let pixels = raster(cell),
                       let cellReference = raster(source,width:cell.width,height:cell.height) {
                        (cellPSNR,cellSSIM) = quality(cellReference.1,pixels.1,width:cell.width,height:cell.height)
                    }
                    print(String(format:"%d,%d,%@,%.2f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.6f,%.3f,%.3f,%.6f",
                                 index,side,type,q,bytes.count,encWall,encCPU,decWall,decCPU,psnr,ssim,cellWall,cellPSNR,cellSSIM))
                    fflush(stdout)
                }
            }}
        }
    }
}
DispatchQueue.global(qos:.utility).async { run(); exit(0) }
dispatchMain()
