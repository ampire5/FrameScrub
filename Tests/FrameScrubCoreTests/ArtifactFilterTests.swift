import Testing
import Metal
@testable import FrameScrubCore

@Suite struct ArtifactFilterSettingsTests {
    @Test func cleanupProfilesPreserveGrainAndDisableChroma() {
        var mild = ArtifactFilterSettings.texturedCleanup(grain: .particles)
        #expect(mild.antiring == .off)
        mild.antiring = .edge
        mild.grainAmount = 2; mild.grainSize = 3; mild.grainBase = 0.4; mild.grainAdaptation = 0.8
        mild.applyCleanup(strong: false)
        var strong = mild
        strong.antiring = .luma
        strong.applyCleanup(strong: true)
        #expect(mild.antiring == .off && strong.antiring == .off)
        #expect(mild.deband == .window && strong.deband == .window)
        #expect(strong.debandStrength > mild.debandStrength)
        #expect(strong.chroma == .off && mild.chroma == .off)
        #expect(strong.textureProtection == 1)
        #expect(strong.grain == .particles && strong.grainAmount == 2 && strong.grainSize == 3)
        #expect(strong.grainBase == 0.4 && strong.grainAdaptation == 0.8)
        #expect(!strong.applies(hdr: true))
    }

    @Test func roundTripAndValidation() {
        let text = "artifact-antiring=edge\nartifact-deband=double\nartifact-chroma=median\nartifact-strength=0.7\nartifact-compare=split\nartifact-dither=0.2"
        let (config, warnings) = Config.parse(text)
        #expect(warnings.isEmpty)
        #expect(config.artifactFilters.antiring == .edge)
        #expect(config.artifactFilters.deband == .double)
        #expect(config.artifactFilters.chroma == .median)
        #expect(config.artifactFilters.strength == 0.7)
        #expect(config.artifactFilters.comparison == .split)
        for key in ["artifact-antiring", "artifact-deband", "artifact-chroma", "artifact-strength", "artifact-compare", "artifact-dither"] {
            let (again, errors) = Config.parse("\(key)=\(config.text(forKey: key)!)")
            #expect(errors.isEmpty)
            #expect(again.text(forKey: key) == config.text(forKey: key))
        }
        let (_, errors) = Config.parse("artifact-strength=2\nartifact-chroma=unknown\nartifact-dither=-1")
        #expect(errors.count == 3)
    }

    @Test func adaptiveSettingsRoundTripAndRangeValidation() {
        let text = "artifact-deband=adaptive\nartifact-antiring=directional\nartifact-deband-threshold=9\nartifact-deband-radius=24\nartifact-texture-protection=0.8"
        let (c,w) = Config.parse(text)
        #expect(w.isEmpty)
        #expect(c.artifactFilters.deband == .adaptive)
        #expect(c.artifactFilters.antiring == .directional)
        #expect(c.artifactFilters.debandThreshold == 9)
        #expect(c.artifactFilters.debandRadius == 24)
        #expect(c.artifactFilters.textureProtection == 0.8)
        for line in text.split(separator: "\n") {
            let key = String(line.split(separator: "=")[0])
            let (again,errors) = Config.parse("\(key)=\(c.text(forKey: key)!)")
            #expect(errors.isEmpty)
            #expect(again.text(forKey: key) == c.text(forKey: key))
        }
        let (_,errors) = Config.parse("artifact-deband-threshold=0\nartifact-deband-threshold=33\nartifact-deband-radius=0\nartifact-deband-radius=65\nartifact-texture-protection=1.1")
        #expect(errors.count == 5)
    }

    @Test func referencePresetMatchesUpstreamSamplingDefaultsWithoutAddedGrain() {
        let s=ArtifactFilterSettings.referencePreset
        #expect(s.deband == .reference)
        #expect(abs(s.debandThreshold/255-0.003)<0.000001)
        #expect(s.debandRadius == 16 && s.debandIterations == 1 && s.debandStrength == 1)
        #expect(s.dither == 0)
        #expect(Config.parse("artifact-deband-threshold=0.765").1.isEmpty)
    }
    @Test func referenceAndWindowSettings() {
        let (c,w) = Config.parse("artifact-deband=reference\nartifact-deband-iterations=3\nartifact-compare=changes")
        #expect(w.isEmpty)
        #expect(c.artifactFilters.deband == .reference)
        #expect(c.artifactFilters.debandIterations == 3)
        #expect(c.artifactFilters.comparison == .changes)
        #expect(Config.parse("artifact-deband=window").0.artifactFilters.deband == .window)
        #expect(Config.parse("artifact-deband-iterations=0\nartifact-deband-iterations=5").1.count == 2)
        #expect(c.text(forKey:"artifact-deband-iterations") == "3")
    }
    @Test func defaultsBypassAndHDRDoNoWork() {
        var s = ArtifactFilterSettings()
        #expect(!s.active)
        s.antiring = .edge
        #expect(s.applies(hdr: false))
        #expect(!s.applies(hdr: true))
        s.comparison = .bypass
        #expect(!s.applies(hdr: false))
        s.comparison = .processed; s.enabled = false
        #expect(!s.applies(hdr: false))
    }
}

@Suite(.serialized) struct ArtifactFilterGPUTests {
    private func processed(_ pixels: [Float16], settings: ArtifactFilterSettings, width: Int = 32, height: Int = 16) throws -> [Float16] {
        let device = try #require(MTLCreateSystemDefaultDevice()), queue = try #require(device.makeCommandQueue())
        let input = try texture(device, width: width, height: height, pixels: pixels), read = try texture(device, width: width, height: height, pixels: pixels)
        let renderer = ArtifactFilterRenderer(device: device), pipes = try ArtifactFilterPipelines(device: device)
        let cb = try #require(queue.makeCommandBuffer())
        let out = renderer.encode(input, source: nil, settings: settings, hdr: false, pipelines: pipes, commandBuffer: cb)
        let blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: out, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: width, height: height, depth: 1), to: read, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        #expect(cb.status == .completed)
        var result = pixels
        read.getBytes(&result, bytesPerRow: width*8, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
        return result
    }
    @Test func medianCleansChromaPreservesLumaAndSplitKeepsOriginalLeft() throws {
        var pixels = [Float16]()
        for _ in 0..<32*16 { pixels += [0.45,0.55,0.5,1] }
        for x in [8,24] { let i = (8*32+x)*4; pixels[i] = 0.7; pixels[i+1] = 0.4; pixels[i+2] = 0.65 }
        var s = ArtifactFilterSettings(); s.chroma = .median; s.chromaStrength = 1
        let out = try processed(pixels, settings: s)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            func luma(_ a: [Float16]) -> Float { Float(a[i]) * 0.2289746 + Float(a[i+1]) * 0.6917385 + Float(a[i+2]) * 0.0792869 }
            #expect(abs(luma(pixels)-luma(out)) < 0.001)
        }
        #expect(abs(Float(out[(8*32+24)*4])-Float(pixels[(8*32+24)*4])) > 0.1)
        s.comparison = .split
        let split = try processed(pixels, settings: s)
        #expect(split[(8*32+8)*4] == pixels[(8*32+8)*4])
        #expect(split[(8*32+24)*4] == out[(8*32+24)*4])
    }
    @Test func debandProducesIntermediateLevelsAndConstantImagesStayConstant() throws {
        var pixels = [Float16]()
        for _ in 0..<16 { for x in 0..<32 { let v: Float16 = x < 16 ? 0.4 : 0.412; pixels += [v,v,v,1] } }
        var s = ArtifactFilterSettings(); s.deband = .double; s.debandStrength = 1
        let out = try processed(pixels, settings: s)
        #expect(stride(from: 0, to: out.count, by: 4).contains { Float(out[$0]) > 0.401 && Float(out[$0]) < 0.411 })
        var constant = [Float16]()
        for _ in 0..<32*16 { constant += [0.5,0.5,0.5,1] }
        s.chroma = .wide
        #expect(try processed(constant, settings: s) == constant)
    }
    @Test func adaptiveDebandSmoothsBandsButProtectsFineLumaAndColorTexture() throws {
        var s = ArtifactFilterSettings(); s.deband = .adaptive; s.debandStrength = 1
        s.debandThreshold = 12; s.debandRadius = 8; s.textureProtection = 1
        var bands = [Float16](), textured = [Float16]()
        for y in 0..<16 { for x in 0..<32 {
            let v: Float = x < 16 ? 0.4 : 0.412
            bands += [Float16(v),Float16(v),Float16(v),1]
            let noise: Float = (x+y)%2 == 0 ? 0.004 : -0.004
            textured += [Float16(v+noise),Float16(v-noise),Float16(v+noise),1]
        } }
        let clean = try processed(bands,settings:s)
        #expect(stride(from:0,to:clean.count,by:4).contains { Float(clean[$0]) > 0.401 && Float(clean[$0]) < 0.411 })
        let preserved = try processed(textured,settings:s)
        let error = zip(textured,preserved).map { abs(Float($0)-Float($1)) }.max()!
        #expect(error < 0.001)
        s.textureProtection = 0
        let unprotected = try processed(textured,settings:s)
        #expect(zip(textured,unprotected).contains { abs(Float($0)-Float($1)) > 0.002 })
    }
    @Test func adaptivePreservesPlaneRealEdgesAndConstantsAndIsDeterministic() throws {
        var s = ArtifactFilterSettings(); s.deband = .adaptive; s.debandStrength = 1; s.debandRadius = 4
        var plane = [Float16](), edges = [Float16](), constant = [Float16]()
        for y in 0..<16 { for x in 0..<32 {
            let v = Float(0.3)+Float(x)*0.001+Float(y)*0.002
            plane += [Float16(v),Float16(v+0.1),Float16(v+0.2),0.75]
            edges += x<16 ? [0.2,0.4,0.5,1] : [0.7,0.3,0.2,1]
            constant += [0.3,0.4,0.5,1]
        } }
        let out = try processed(plane,settings:s)
        for y in 4..<12 { for x in 4..<28 { for c in 0..<4 {
            let i=(y*32+x)*4+c; #expect(abs(Float(out[i])-Float(plane[i])) < 0.001)
        } } }
        #expect(try processed(edges,settings:s) == edges)
        #expect(try processed(constant,settings:s) == constant)
        #expect(try processed(plane,settings:s) == out)
        s.debandStrength=0
        #expect(try processed(plane,settings:s) == plane)
    }
    @Test func directionalCleanupSuppressesSmallOscillationsAndPreservesStrongEdges() throws {
        var s = ArtifactFilterSettings();s.antiring = .directional;s.antiringStrength=1
        var noisy = [Float16](), edge = [Float16]()
        for _ in 0..<16 { for x in 0..<32 {
            let v: Float16 = x%2 == 0 ? 0.49:0.51
            noisy += [v,v,v,1];edge += x<16 ? [0.2,0.2,0.2,1]:[0.8,0.8,0.8,1]
        } }
        let out = try processed(noisy,settings:s)
        #expect(abs(Float(out[(8*32+16)*4])-0.5) < abs(Float(noisy[(8*32+16)*4])-0.5))
        #expect(try processed(edge,settings:s) == edge)
    }
    @Test func adaptiveAndDirectionalHandleTinyConstantInputs() throws {
        for (w,h) in [(1,1),(1,2),(2,1),(3,3)] {
            let color: [Float16] = [0.3,0.4,0.5,0.75]
            let pixels: [Float16] = Array(repeating: color, count:w*h).flatMap { $0 }
            for directional in [false,true] {
                var s = ArtifactFilterSettings()
                if directional { s.antiring = .directional } else { s.deband = .adaptive;s.debandRadius=64 }
                #expect(try processed(pixels,settings:s,width:w,height:h) == pixels)
            }
        }
    }
    @Test func referenceThresholdsEachChannelAndIterationsActuallyChangeOutput() throws {
        var pixels=[Float16]()
        for _ in 0..<16 {for x in 0..<32 {pixels += x<16 ? [0.4,0.2,0.4,0.75]:[0.412,0.8,0.412,0.75]}}
        var s=ArtifactFilterSettings();s.deband = .reference;s.debandStrength=1;s.debandThreshold=9;s.debandRadius=12
        let out=try processed(pixels,settings:s)
        #expect(stride(from:0,to:out.count,by:4).contains { abs(Float(out[$0])-Float(pixels[$0])) > 0.001 })
        for i in stride(from:0,to:out.count,by:4) {
            #expect(out[i+1] == pixels[i+1]);#expect(out[i+3] == pixels[i+3])
        }
        s.debandIterations=3
        #expect(try processed(pixels,settings:s) != out)
    }
    @Test func windowShrinksNearEdgesAndChangesViewShowsModifiedPixels() throws {
        var pixels=[Float16]()
        for _ in 0..<16 {for x in 0..<32 {let v:Float16=x<16 ? (x<8 ? 0.4:0.412):0.8;pixels += [v,v,v,1]}}
        var s=ArtifactFilterSettings();s.deband = .window;s.debandStrength=1;s.debandRadius=24;s.debandThreshold=12
        let out=try processed(pixels,settings:s)
        #expect((1..<15).contains {abs(Float(out[(8*32+$0)*4])-Float(pixels[(8*32+$0)*4])) > 0.001})
        for x in 16..<32 {#expect(out[(8*32+x)*4] == pixels[(8*32+x)*4])}
        s.comparison = .changes
        let heat=try processed(pixels,settings:s)
        #expect(heat != out)
        #expect((1..<15).contains {Float(heat[(8*32+$0)*4]) > Float(heat[(8*32+$0)*4+1])+0.1})
    }
    @Test func adaptiveProtectsIsoluminantTextureAndPlanarBorders() throws {
        var texture=[Float16](),plane=[Float16]()
        for y in 0..<16 {for x in 0..<32 {
            let delta:Float=(x+y)%2==0 ? 0.006:-0.006
            texture += [Float16(0.5+delta),Float16(0.5-delta*0.2289746/0.6917385),0.5,1]
            let v=Float(0.3)+Float(x)*0.001+Float(y)*0.002
            plane += [Float16(v),Float16(v+0.1),Float16(v+0.2),0.75]
        }}
        for mode in [ArtifactFilterSettings.Deband.adaptive,.window] {
            var s=ArtifactFilterSettings();s.deband=mode;s.debandStrength=1;s.debandRadius=8
            let t=try processed(texture,settings:s),g=try processed(plane,settings:s)
            #expect(zip(t,texture).allSatisfy {abs(Float($0)-Float($1)) < 0.001})
            #expect(zip(g,plane).allSatisfy {abs(Float($0)-Float($1)) < 0.001})
        }
    }
    private func texture(_ device: MTLDevice, width: Int = 32, height: Int = 16, pixels: [Float16]) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
        let t = try #require(device.makeTexture(descriptor: d))
        pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return t
    }
    @Test func realLumaLimiterAndBypass() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let queue = try #require(device.makeCommandQueue())
        let pipes = try ArtifactFilterPipelines(device: device)
        var source = [Float16](), exaggerated = [Float16]()
        for _ in 0..<16 { for x in 0..<32 {
            let s: Float16 = x < 16 ? 0.2 : 0.8, v: Float16 = x < 16 ? 0.15 : 0.85
            source += [s,s,s,1]; exaggerated += [v,v,v,1]
        } }
        let src = try texture(device, pixels: source), input = try texture(device, pixels: exaggerated)
        let renderer = ArtifactFilterRenderer(device: device)
        var settings = ArtifactFilterSettings(); settings.antiring = .luma
        let cb = try #require(queue.makeCommandBuffer())
        let out = renderer.encode(input, source: src, settings: settings, hdr: false, pipelines: pipes, commandBuffer: cb)
        let read = try texture(device, pixels: exaggerated)
        let blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: out, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: 32, height: 16, depth: 1), to: read, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        #expect(cb.status == .completed)
        var values = [Float16](repeating: 0, count: 32*16*4)
        read.getBytes(&values, bytesPerRow: 32*8, from: MTLRegionMake2D(0,0,32,16), mipmapLevel: 0)
        #expect(Float(values[0]) >= 0.191)
        #expect(Float(values[(31)*4]) <= 0.809)
        settings.comparison = .bypass
        let bypassCB = try #require(queue.makeCommandBuffer())
        #expect(renderer.encode(input, source: src, settings: settings, hdr: false, pipelines: pipes, commandBuffer: bypassCB) === input)
        #expect(renderer.encode(input, source: src, settings: settings, hdr: true, pipelines: pipes, commandBuffer: bypassCB) === input)
        for directional in [false,true] {
            var s = ArtifactFilterSettings()
            if directional { s.antiring = .directional } else { s.deband = .adaptive }
            #expect(renderer.encode(input, source: nil, settings: s, hdr: true, pipelines: pipes, commandBuffer: bypassCB) === input)
            s.strength = 0
            #expect(renderer.encode(input, source: nil, settings: s, hdr: false, pipelines: pipes, commandBuffer: bypassCB) === input)
        }
        bypassCB.commit(); bypassCB.waitUntilCompleted()
    }
}
