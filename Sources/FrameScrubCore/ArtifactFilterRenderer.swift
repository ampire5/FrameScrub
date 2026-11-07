import Foundation
import Metal

/// Immutable pipelines; construct off-main and share between fit/zoom/original/LL scalers.
public final class ArtifactFilterPipelines: @unchecked Sendable {
    fileprivate let states: [String: MTLComputePipelineState]
    let grain: PerceptualGrainPipelines
    public init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: [ArtifactFilterKernels.source, ReferenceDebandKernel.source, PerceptualGrainPipelines.source].joined(separator: "\n"), options: nil)
        grain = try PerceptualGrainPipelines(device: device, library: library)
        var result: [String: MTLComputePipelineState] = [:]
        for name in ["ar", "directional", "adaptiveDeband", "windowDeband", "referenceDeband", "changes", "colorClean", "deband", "dither", "compare"] {
            guard let function = library.makeFunction(name: name) else { throw NSError(domain: "ArtifactFilters", code: 1) }
            result[name] = try device.makeComputePipelineState(function: function)
        }
        states = result
    }
}

/// One queue's display encoder. Only two reusable full-output scratch textures, no CPU readback.
/// The command buffer retains encoded textures through completion, including after a size change.
public final class ArtifactFilterRenderer {
    private let device: MTLDevice
    private var scratch: [MTLTexture] = []
    private(set) var scratchAllocations = 0
    public private(set) var status = "Filters: off"
    public var allocatedBytes: Int { scratch.reduce(0) { $0 + $1.allocatedSize } }
    private struct Parameters {
        var strength: Float = 1; var threshold: Float = 0; var radius: Float = 0; var dither: Float = 0
        var mode: UInt32 = 0; var pass: UInt32 = 0; var comparison: UInt32 = 0; var protection: Float = 0
    }
    public init(device: MTLDevice) { self.device = device }
    public func clear() { scratch.removeAll() }
    /// Compares final scaled images. Keeps an unfiltered baseline separate from pre-scale cleanup.
    public func encodeComparison(original: MTLTexture, processed: MTLTexture, comparison: ArtifactFilterSettings.Comparison,
                                 pipelines: ArtifactFilterPipelines, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        guard comparison == .split || comparison == .changes else { return processed }
        guard ensureScratch(processed), let target = scratch.first(where: { $0 !== processed && $0 !== original }),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              let pipeline = pipelines.states[comparison == .split ? "compare":"changes"] else {
            status = "Filters: comparison encoder failed"; return processed
        }
        encoder.label = "Filter Lab: final comparison"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(original,index:0);encoder.setTexture(processed,index:1);encoder.setTexture(target,index:2)
        encoder.dispatchThreads(.init(width:processed.width,height:processed.height,depth:1),threadsPerThreadgroup:.init(width:16,height:8,depth:1))
        encoder.endEncoding();return target
    }
    private func ensureScratch(_ input:MTLTexture)->Bool {
        if scratch.first?.width == input.width && scratch.first?.height == input.height {return true}
        clear()
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:input.width,height:input.height,mipmapped:false)
        d.storageMode = .private;d.usage = [.shaderRead,.shaderWrite,.renderTarget]
        guard let a=device.makeTexture(descriptor:d),let b=device.makeTexture(descriptor:d) else {return false}
        scratch=[a,b];scratchAllocations += 1;return true
    }
    /// Shared with the fused post stage. Comparison excludes this target when choosing scratch.
    func reusableTarget(for input:MTLTexture)->MTLTexture? {
        guard ensureScratch(input) else {return nil}
        status = "Filters: fused AR + grain"
        return scratch.first {$0 !== input}
    }
    public func encode(_ input: MTLTexture, source: MTLTexture?, settings: ArtifactFilterSettings, hdr: Bool,
                       pipelines: ArtifactFilterPipelines?, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        status = settings.summary
        guard settings.applies(hdr: hdr) else {
            if hdr && settings.active { status = "Filters: HDR bypass" }
            clear(); return input
        }
        if source == nil && settings.antiring != .directional && settings.chroma == .off && settings.deband == .off && settings.dither == 0 {
            status = "Filters: AR needs MetalFX"; clear(); return input
        }
        guard let pipelines else { status = "Filters: preparing"; return input }
        guard ensureScratch(input) else {status = "Filters: texture allocation failed";return input}
        var current = input, next = 0
        func run(_ name: String, textures: [MTLTexture], params: Parameters = .init()) -> Bool {
            guard let encoder = commandBuffer.makeComputeCommandEncoder(), let pipeline = pipelines.states[name] else { return false }
            let target = scratch[next]
            encoder.label = "Filter Lab: \(name)"
            encoder.setComputePipelineState(pipeline)
            for (i,t) in (textures + [target]).enumerated() { encoder.setTexture(t, index: i) }
            var p = params; encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: input.width, height: input.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            encoder.endEncoding(); current = target; next = 1-next; return true
        }
        var p = Parameters()
        if settings.antiring == .directional, settings.antiringStrength > 0 {
            p.strength = Float(settings.strength * settings.antiringStrength); p.threshold = 8/255
            guard run("directional", textures: [current], params: p) else { status = "Filters: encoder failed"; return input }
        } else if settings.antiring != .off, settings.antiringStrength > 0, let source {
            p.strength = Float(settings.strength * settings.antiringStrength); p.mode = settings.antiring == .edge ? 2:1
            guard run("ar", textures: [source,current], params: p) else { status = "Filters: encoder failed"; return input }
        }
        if settings.chroma != .off, settings.chromaStrength > 0 {
            p = .init(); p.strength = Float(settings.strength * settings.chromaStrength)
            p.mode = settings.chroma == .median ? 3 : settings.chroma == .wide ? 2:1
            guard run("colorClean", textures: [current], params: p) else { status = "Filters: encoder failed"; return input }
        }
        if settings.deband != .off, settings.debandStrength > 0 {
            p = .init(); p.strength = Float(settings.strength * settings.debandStrength)
            if [.adaptive,.window,.reference].contains(settings.deband) {
                p.threshold = Float(settings.debandThreshold / 255); p.radius = Float(settings.debandRadius)
                p.protection = Float(settings.textureProtection); p.mode = UInt32(settings.debandIterations)
            } else {
                p.threshold = (2 + 14*p.strength)/255; p.radius = 8 + 24*p.strength
            }
            for iteration in 0..<(settings.deband == .double ? 2:1) {
                p.pass = UInt32(iteration); p.radius *= iteration == 0 ? 1:1.5; p.threshold *= iteration == 0 ? 1:0.75
                let kernel = settings.deband == .adaptive ? "adaptiveDeband" : settings.deband == .window ? "windowDeband" : settings.deband == .reference ? "referenceDeband" : "deband"
                guard run(kernel, textures: [current], params: p) else { status = "Filters: encoder failed"; return input }
            }
        }
        if settings.dither > 0 {
            p = .init(); p.dither = Float(settings.dither * settings.strength)
            guard run("dither", textures: [current], params: p) else { status = "Filters: encoder failed"; return input }
        }
        if settings.comparison == .split, current !== input {
            guard run("compare", textures: [input,current]) else { status = "Filters: encoder failed"; return input }
        }
        if settings.comparison == .changes, current !== input {
            guard run("changes", textures: [input,current]) else { status = "Filters: encoder failed"; return input }
        }
        if source == nil && settings.antiring != .off && settings.antiring != .directional { status += "; AR needs MetalFX" }
        return current
    }
}
