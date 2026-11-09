import Foundation
import Metal

/// Immutable, neutral offline-generated patterns. Load only during off-main pipeline preparation.
/// Provenance and licenses are bundled with the banks, not fetched at runtime.
enum GrainTemplateBank {
    private final class Locator {}
    static let side = 64
    static let layers = 16

    static func load(_ name: String, device: MTLDevice) throws -> MTLTexture {
        // Match SwiftPM's app/framework/CLI locations, throwing if packaging is incomplete.
        var roots = [Bundle.main.resourceURL, Bundle(for: Locator.self).resourceURL, Bundle.main.bundleURL]
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] {
            roots.insert(URL(fileURLWithPath: path, isDirectory: true), at: 0)
        }
        #endif
        let bundle = roots.compactMap { $0 }.lazy.compactMap {
            Bundle(url: $0.appendingPathComponent("FrameScrub_FrameScrubCore.bundle"))
        }.first
        guard let url = bundle?.url(forResource: name, withExtension: "r16f", subdirectory: "GrainTemplates") else {
            throw NSError(domain: "GrainTemplates", code: 1)
        }
        let data = try Data(contentsOf: url)
        guard data.count == side*side*layers*2 else { throw NSError(domain: "GrainTemplates", code: 2) }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray; descriptor.pixelFormat = .r16Float
        descriptor.width = side; descriptor.height = side; descriptor.arrayLength = layers
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw NSError(domain: "GrainTemplates", code: 3) }
        data.withUnsafeBytes { bytes in
            for layer in 0..<layers {
                texture.replace(region: MTLRegionMake2D(0,0,side,side), mipmapLevel: 0, slice: layer,
                                withBytes: bytes.baseAddress!.advanced(by: layer*side*side*2), bytesPerRow: side*2,
                                bytesPerImage: side*side*2)
            }
        }
        return texture
    }
}
