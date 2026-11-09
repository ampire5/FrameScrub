import Testing
import Metal
import MetalFX
import CoreImage
@testable import FrameScrubCore

@Suite(.serialized) struct PerceptualGrainTests {
    @Test func settingsRoundTripDefaultsAndRanges() {
        #expect(ArtifactFilterSettings().grain == .off)
        let text = "artifact-grain=soft\nartifact-grain-amount=0.8\nartifact-grain-size=1.5\nartifact-grain-base=0.3\nartifact-grain-adaptation=0.9"
        let (c, warnings) = Config.parse(text)
        #expect(warnings.isEmpty)
        #expect(c.artifactFilters.grain == .soft)
        #expect(c.artifactFilters.active)
        for line in text.split(separator: "\n") {
            let key = String(line.split(separator: "=")[0])
            let (again, errors) = Config.parse("\(key)=\(c.text(forKey:key) ?? "missing")")
            #expect(errors.isEmpty)
            #expect(again.text(forKey:key) == c.text(forKey:key))
        }
        #expect(Config.parse("artifact-grain=unknown\nartifact-grain-amount=12.1\nartifact-grain-size=0\nartifact-grain-base=-1\nartifact-grain-adaptation=2").1.count == 5)
    }

    @Test(arguments: ["av1", "particles"])
    func candidateConfigRangeAndRoundTrip(mode: String) {
        for amount in [6, 12] {
            let (c, warnings) = Config.parse("artifact-grain=\(mode)\nartifact-grain-amount=\(amount)")
            #expect(warnings.isEmpty)
            #expect(c.artifactFilters.grain.rawValue == mode)
            #expect(c.artifactFilters.grainAmount == Double(amount))
            #expect(c.text(forKey: "artifact-grain") == mode)
        }
    }

    @Test func candidateBanksAreVisibleDistinctAndProtected() throws {
        let flat = [Half](repeating: 0.5, count: 128*64*4)
        var outputs = [[Half]]()
        for mode in ["av1", "particles"] {
            var s = Config.parse("artifact-grain=\(mode)\nartifact-grain-amount=6\nartifact-grain-size=2\nartifact-grain-base=0.8").0.artifactFilters
            let result = try run(flat, settings:s)
            #expect(result == (try run(flat, settings:s)))
            #expect(result != (try run(flat, seed:8, settings:s)))
            let rms = sqrt(stride(from:0,to:result.count,by:4).reduce(0.0) { $0 + pow(Double(Float(result[$1]) - 0.5),2) } / Double(128*64))
            #expect(rms*255 > 2)
            var texture=flat
            for y in 0..<64 {for x in 0..<128 {
                let i=(y*128+x)*4
                texture[i] = (x+y)%2 == 0 ? 0.4:0.6
                texture[i+1] = (x+y)%2 == 0 ? 0.6:0.4
            }}
            #expect(try run(texture,settings:s) == texture)
            s.grainAdaptation=0
            #expect(try run(texture,settings:s) != texture)
            outputs.append(result)
        }
        #expect(outputs[0] != outputs[1])
    }

    @Test func missingTemplateThrowsDuringPreparation() throws {
        let gpu=try #require(MTLCreateSystemDefaultDevice())
        #expect(throws: Error.self) { try GrainTemplateBank.load("missing",device:gpu) }
    }

    private func texture(_ gpu: MTLDevice, _ w: Int, _ h: Int, _ pixels: [Half]) throws -> MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:w,height:h,mipmapped:false)
        d.storageMode = .shared; d.usage=[.shaderRead,.shaderWrite,.renderTarget]
        let t=try #require(gpu.makeTexture(descriptor:d))
        pixels.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*8) }
        return t
    }
    private func run(_ pixels:[Half], cleaned:[Half]?=nil, w:Int=128,h:Int=64, seed:UInt32=7,
                     settings:ArtifactFilterSettings) throws -> [Half] {
        let gpu=try #require(MTLCreateSystemDefaultDevice()),queue=try #require(gpu.makeCommandQueue())
        let a=try texture(gpu,w,h,pixels),b=try texture(gpu,w,h,cleaned ?? pixels),read=try texture(gpu,w,h,pixels)
        let pipes=try ArtifactFilterPipelines(device:gpu),r=PerceptualGrainRenderer(device:gpu)
        let cb=try #require(queue.makeCommandBuffer())
        #expect(r.prepareMask(original:a,cleaned:b,settings:settings,pipelines:pipes,commandBuffer:cb))
        let out=r.encode(b,settings:settings,seed:seed,pipelines:pipes,commandBuffer:cb)
        let blit=try #require(cb.makeBlitCommandEncoder());blit.copy(from:out,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(),sourceSize:.init(width:w,height:h,depth:1),to:read,destinationSlice:0,destinationLevel:0,destinationOrigin:.init());blit.endEncoding()
        cb.commit();cb.waitUntilCompleted();#expect(cb.status == .completed)
        var result=pixels;result.withUnsafeMutableBytes { read.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) };return result
    }
    @Test func flatGrainIsZeroMeanAchromaticAndDeterministic() throws {
        let a=[Half](repeating:0.5,count:128*64*4)
        var s=ArtifactFilterSettings();s.grain = .fine;s.grainAmount=1;s.grainBase=1
        let b=try run(a,settings:s),same=try run(a,settings:s),other=try run(a,seed:8,settings:s)
        #expect(b==same);#expect(b != other)
        var mean=0.0,energy=0.0
        for i in stride(from:0,to:a.count,by:4) {
            let d=Double(Float(b[i])-Float(a[i]))*255;mean+=d;energy+=d*d
            #expect(b[i]==b[i+1] && b[i+1]==b[i+2]);#expect(b[i+3]==a[i+3])
            #expect(abs(d)<5)
        }
        #expect(abs(mean/8192)<0.08);#expect(energy/8192>0.5 && energy/8192<1.5)
    }
    @Test func preservedLumaAndColorTextureRejectGrain() throws {
        var s=ArtifactFilterSettings();s.grain = .soft;s.grainAmount=1;s.grainBase=1
        for color in [false,true] {
            var a=[Half]()
            for y in 0..<64 {for x in 0..<128 {
                let v:Float=(x+y)%2==0 ? 0.08:-0.08
                a += color ? [Half(0.5+v),Half(0.5-v*0.2289746/0.6917385),0.5,1] : [Half(0.5+v),Half(0.5+v),Half(0.5+v),1]
            }}
            #expect(try run(a,settings:s)==a)
        }
    }
    @Test func removedWeakTextureGetsMoreGrainThanInitiallyFlat() throws {
        let flat=[Half](repeating:0.5,count:128*64*4);var rough=flat
        for y in 0..<64 {for x in 0..<128 {for c in 0..<3 {rough[(y*128+x)*4+c]=Half(0.5+((x+y)%2==0 ? 0.004:-0.004))}}}
        var s=ArtifactFilterSettings();s.grain = .fine;s.grainAmount=1;s.grainBase=0.2
        let a=try run(flat,settings:s),b=try run(rough,cleaned:flat,settings:s)
        func energy(_ p:[Half])->Double {stride(from:0,to:p.count,by:4).reduce(0){$0+pow(Double(Float(p[$1])-0.5),2)}}
        #expect(energy(b)>energy(a)*2)
    }
    @Test func textureAtEverySourcePixelPhaseIsProtected() throws {
        var s=ArtifactFilterSettings();s.grain = .fine;s.grainAmount=1;s.grainBase=1
        for phase in 0..<4 {
            var a=[Half](repeating:0.5,count:128*64*4)
            for y in 0..<64 {for x in 0..<128 where x%2==phase%2 && y%2==phase/2 {
                for c in 0..<3 {a[(y*128+x)*4+c]=0.58}
            }}
            #expect(try run(a,settings:s)==a)
        }
    }
    @Test func tinyTexturesAndOffRelease() throws {
        var s=ArtifactFilterSettings();s.grain = .fine
        #expect(try run([0.5,0.5,0.5,1],w:1,h:1,settings:s).count==4)
        let gpu=try #require(MTLCreateSystemDefaultDevice()),r=PerceptualGrainRenderer(device:gpu)
        r.clear();#expect(r.allocatedBytes==0)
    }
    @Test(arguments:[ScaleMode.metalfx,.lanczos,.bilinear], ["fine", "av1", "particles"])
    func scalerPauseSplitBypassAndHDR(mode:ScaleMode, grainMode:String) throws {
        let gpu=try #require(MTLCreateSystemDefaultDevice()),q=try #require(gpu.makeCommandQueue())
        let ci=CIContext(mtlDevice:gpu,options:[.cacheIntermediates:false]),color=CGColorSpace(name:CGColorSpace.displayP3)!
        let source=CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5,colorSpace:color)!).cropped(to:CGRect(x:0,y:0,width:64,height:32))
        let scaler=DisplayScaler(device:gpu,context:ci),pipes=try ArtifactFilterPipelines(device:gpu)
        func render(_ s:ArtifactFilterSettings,_ seed:UInt32=11,_ hdr:Bool=false,_ sharp:Double=0)->[Half] {
            let cb=q.makeCommandBuffer()!,im=scaler.scaled(source,to:CGSize(width:128,height:64),mode:mode,sharpen:sharp,hdr:hdr,artifactSettings:s,artifactPipelines:pipes,grainSeed:seed,commandBuffer:cb)
            cb.commit();cb.waitUntilCompleted();#expect(cb.status == .completed)
            var a=[Half](repeating:0,count:128*64*4);a.withUnsafeMutableBytes{ci.render(im,toBitmap:$0.baseAddress!,rowBytes:128*8,bounds:CGRect(x:0,y:0,width:128,height:64),format:.RGBAh,colorSpace:color)};return a
        }
        var s=ArtifactFilterSettings();s.grain = try #require(ArtifactFilterSettings.Grain(rawValue:grainMode));s.grainAmount=grainMode == "fine" ? 1:6;s.grainBase=1
        for sharp in [0.0,0.5] {
            let base=render(.init(),11,false,sharp),processed=render(s,11,false,sharp)
            #expect(base != processed);#expect(render(s,11,false,sharp)==processed)
            // Finite CI images have transparent borders. Check the constant interior:
            // sharpening must not amplify the subsequently added grain.
            let unsharpened=render(s,11,false,0),plain=render(.init(),11,false,0)
            var maxGrainDelta:Float=0
            for y in 12..<52 {for x in 12..<116 {
                let i=(y*128+x)*4
                maxGrainDelta=max(maxGrainDelta,abs((Float(processed[i])-Float(base[i]))-(Float(unsharpened[i])-Float(plain[i]))))
            }}
            #expect(maxGrainDelta<0.001)
            #expect(render(s,12,false,sharp) != processed)
            s.comparison = .split;let split=render(s,11,false,sharp)
            let allocations=scaler.comparisonAllocationCount
            _=render(s,11,false,sharp)
            #expect(scaler.comparisonAllocationCount==allocations)
            for y in 0..<64 {for x in 0..<128 where x != 64 {let i=(y*128+x)*4
                #expect(abs(Float(split[i])-Float(x<64 ? base[i]:processed[i]))<0.001)
            }}
            s.comparison = .processed
        }
        s.comparison = .bypass;#expect(render(s)==render(.init()))
        s.comparison = .changes;#expect(render(s) != render(.init()))
        s.comparison = .processed;#expect(render(s,11,true)==render(.init(),11,true))
        _=render(.init());#expect(scaler.grainScratchBytes==0)
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice().map { MTLFXSpatialScalerDescriptor.supportsDevice($0) } ?? false, "MetalFX unsupported"), arguments:[ArtifactFilterSettings.Antiring.luma,.edge], ["fine", "av1", "particles"])
    func fusedMatchesSeparateAndRetainsFallbacks(ar:ArtifactFilterSettings.Antiring, grainMode:String) throws {
        let gpu=try #require(MTLCreateSystemDefaultDevice()),q=try #require(gpu.makeCommandQueue())
        let ci=CIContext(mtlDevice:gpu,options:[.cacheIntermediates:false]),color=CGColorSpace(name:CGColorSpace.displayP3)!
        var a=[Half]()
        for y in 0..<32 {for x in 0..<64 {
            let v:Float=(x<32 ? 0.25:0.65)+Float((x+y)%3)*0.004
            a += [Half(v),Half(v+0.02),Half(v-0.01),1]
        }}
        let original=try texture(gpu,64,32,a),clean=try texture(gpu,64,32,a),scaled=try texture(gpu,128,64,[Half](repeating:0,count:128*64*4))
        let source=try #require(CIImage(mtlTexture:original,options:[.colorSpace:color])),pipes=try ArtifactFilterPipelines(device:gpu)
        var s=ArtifactFilterSettings();s.antiring=ar;s.grain = try #require(ArtifactFilterSettings.Grain(rawValue:grainMode));s.grainAmount=1;s.grainBase=0.4
        var arOnly=s;arOnly.grain = .off
        let expectedScaler=DisplayScaler(device:gpu,context:ci),actualScaler=DisplayScaler(device:gpu,context:ci)
        let cb=try #require(q.makeCommandBuffer())
        ci.render(source,to:clean,commandBuffer:cb,bounds:source.extent,colorSpace:color)
        let base=expectedScaler.scaled(source,to:CGSize(width:128,height:64),mode:.metalfx,sharpen:0,hdr:false,artifactSettings:arOnly,artifactPipelines:pipes,commandBuffer:cb)
        ci.render(base,to:scaled,commandBuffer:cb,bounds:base.extent,colorSpace:color)
        let grain=PerceptualGrainRenderer(device:gpu)
        #expect(grain.prepareMask(original:clean,cleaned:clean,settings:s,pipelines:pipes,commandBuffer:cb))
        let expected=grain.encode(scaled,settings:s,seed:23,pipelines:pipes,commandBuffer:cb)
        let actual=actualScaler.scaled(source,to:CGSize(width:128,height:64),mode:.metalfx,sharpen:0,hdr:false,artifactSettings:s,artifactPipelines:pipes,grainSeed:23,commandBuffer:cb)
        cb.commit();cb.waitUntilCompleted();#expect(cb.status == .completed)
        #expect(actualScaler.grainUsesFusedPass)
        #expect(actualScaler.grainScratchBytes<128*64*8)
        func read(_ image:CIImage)->[Half] {
            var p=[Half](repeating:0,count:128*64*4)
            p.withUnsafeMutableBytes{ci.render(image,toBitmap:$0.baseAddress!,rowBytes:128*8,bounds:CGRect(x:0,y:0,width:128,height:64),format:.RGBAh,colorSpace:color)};return p
        }
        let expectedPixels=read(try #require(CIImage(mtlTexture:expected,options:[.colorSpace:color]))),actualPixels=read(actual)
        let delta=zip(expectedPixels,actualPixels).map{abs(Float($0)-Float($1))}.max()!
        #expect(delta<0.001)
        func fallback(_ settings:ArtifactFilterSettings,_ sharpen:Double) {
            let c=q.makeCommandBuffer()!
            _=actualScaler.scaled(source,to:CGSize(width:128,height:64),mode:.metalfx,sharpen:sharpen,hdr:false,artifactSettings:settings,artifactPipelines:pipes,grainSeed:23,commandBuffer:c)
            c.commit();c.waitUntilCompleted();#expect(c.status == .completed)
            #expect(!actualScaler.grainUsesFusedPass)
        }
        fallback(s,0.5);s.dither=0.2;fallback(s,0)
    }
}
