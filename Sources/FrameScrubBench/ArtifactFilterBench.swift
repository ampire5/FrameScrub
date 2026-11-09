import Foundation
import Metal
import MetalFX
import CoreImage
import FrameScrubCore

/// Actual MetalFX + experimental-filter command buffers, serially on bounded resident textures.
enum ArtifactFilterBench {
    static func main() -> Never {
        do {
            let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
            let start = ProcessInfo.processInfo.systemUptime
            let pipes = try ArtifactFilterPipelines(device: device)
            print("pipeline preparation ms: \((ProcessInfo.processInfo.systemUptime-start)*1000)")
            for (w,h,ow,oh) in [(1920,1080,3840,2160),(3840,2160,5120,2880)] {
                try autoreleasepool {
                    func tex(_ width: Int,_ height: Int,_ storage: MTLStorageMode) -> MTLTexture {
                        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                        d.storageMode = storage; d.usage = [.shaderRead,.shaderWrite,.renderTarget]
                        return device.makeTexture(descriptor: d)!
                    }
                    let upload = tex(w,h,.shared), source = tex(w,h,.private), base = tex(ow,oh,.private)
                    var pixels = [Half](repeating: 1, count: w*h*4)
                    for y in 0..<h { for x in 0..<w {
                        let v = Float((x/8)%64)/128 + (x%320<160 ? 0.1:0.4)
                        let i = (y*w+x)*4; pixels[i] = Half(v); pixels[i+1] = Half(v+Float((x+y)%3)*0.008); pixels[i+2] = Half(v)
                    } }
                    pixels.withUnsafeBytes { upload.replace(region: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w*8) }
                    let cb = queue.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
                    blit.copy(from: upload, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width:w,height:h,depth:1), to: source, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
                    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                    let d = MTLFXSpatialScalerDescriptor(); d.inputWidth=w;d.inputHeight=h;d.outputWidth=ow;d.outputHeight=oh;d.colorTextureFormat = .rgba16Float;d.outputTextureFormat = .rgba16Float;d.colorProcessingMode = .perceptual
                    let fx = d.makeSpatialScaler(device: device)!
                    fx.colorTexture=source;fx.outputTexture=base;fx.inputContentWidth=w;fx.inputContentHeight=h
                    let renderer = ArtifactFilterRenderer(device: device)
                    var profiles: [(String,ArtifactFilterSettings)] = [("off",.init())]
                    var s = ArtifactFilterSettings();s.antiring = .edge;profiles.append(("edge",s));s.antiring = .luma;profiles.append(("luma",s))
                    s = .init();s.deband = .single;profiles.append(("deband1",s));s.deband = .double;profiles.append(("deband2",s))
                    s = .init();s.deband = .adaptive;profiles.append(("adaptive",s));s.textureProtection=0;profiles.append(("adaptive-no-protection",s))
                    s = .init();s.deband = .window;profiles.append(("adaptive-window",s));s.textureProtection=0;profiles.append(("window-no-protection",s))
                    s = .init();s.deband = .reference;profiles.append(("reference1",s));s.debandIterations=3;profiles.append(("reference3",s));s.debandIterations=4;profiles.append(("reference4",s))
                    s = .init();s.antiring = .directional;profiles.append(("directional",s))
                    s = .init();s.chroma = .bilateral;profiles.append(("bilateral3",s));s.chroma = .wide;profiles.append(("bilateral5",s));s.chroma = .median;profiles.append(("median3",s))
                    s = .init();s.antiring = .edge;s.chroma = .bilateral;s.chromaStrength=0.35;s.deband = .single;s.debandStrength=0.3;profiles.append(("combined",s));s.comparison = .split;profiles.append(("combined-split",s))
                    profiles.append(("reference-default",.referencePreset))
                    for (name,settings) in profiles {
                        var samples: [Double] = []
                        for i in 0..<23 {
                            let cb = queue.makeCommandBuffer()!;fx.encode(commandBuffer: cb)
                            _ = renderer.encode(base, source: source, settings: settings, hdr: false, pipelines: pipes, commandBuffer: cb)
                            cb.commit();cb.waitUntilCompleted()
                            guard cb.status == .completed else { throw cb.error ?? NSError(domain:"GPU",code:1) }
                            if i>=3 {samples.append((cb.gpuEndTime-cb.gpuStartTime)*1000)}
                        }
                        let a = samples.sorted();let row: [String:Any] = ["output":"\(ow)x\(oh)","profile":name,"gpu_median_ms":a[a.count/2],"gpu_p95_ms":a[18],"samples":samples,"scratch_bytes":renderer.allocatedBytes]
                        let data = try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]);print(String(decoding:data,as:UTF8.self))
                    }
                }
            }
            exit(0)
        } catch { fail("filters: \(error)") }
    }
    /// Controlled public synthetic fixture; PNG/readback work is outside the playback pipeline.
    static func fixtures(_ arguments: [String]) -> Never {
        do {
            guard let directory = arguments.first else { fail("filter-fixtures <output-directory>") }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
            let pipes = try ArtifactFilterPipelines(device: device), renderer = ArtifactFilterRenderer(device: device)
            let w=1280,h=720
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:w,height:h,mipmapped:false)
            d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite]
            let input = device.makeTexture(descriptor:d)!,read=device.makeTexture(descriptor:d)!
            var pixels=[Half](),ideal=[Float]()
            pixels.reserveCapacity(w*h*4);ideal.reserveCapacity(w*h*4)
            for y in 0..<h { for x in 0..<w {
                let ramp=0.25+0.5*Float(x)/Float(w-1)
                let band=round(ramp*64)/64
                let texture: Float = y>=h/3 && y<2*h/3 ? ((x+y)%2 == 0 ? 0.004 : -0.004):0
                let v: Float = y>=2*h/3 ? (x<w/2 ? 0.25:0.75):band
                let truth: Float = y>=2*h/3 ? v:ramp
                pixels += [Half(v+texture),Half(v-texture),Half(v+texture),1]
                ideal += [truth+texture,truth-texture,truth+texture,1]
            } }
            pixels.withUnsafeBytes { input.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*8) }
            var profiles:[(String,ArtifactFilterSettings)]=[("input",.init())]
            var s=ArtifactFilterSettings();s.deband = .single;profiles.append(("single",s))
            s.deband = .adaptive;profiles.append(("adaptive",s));s.comparison = .changes;profiles.append(("adaptive-changes",s));s.comparison = .processed
            s.deband = .window;profiles.append(("window",s));s.deband = .reference;profiles.append(("reference1",s));s.debandIterations=3;profiles.append(("reference3",s));s.debandIterations=1;s.deband = .adaptive
            s.textureProtection=0;profiles.append(("adaptive-unprotected",s))
            s = .init();s.antiring = .directional;profiles.append(("directional",s))
            profiles.append(("reference-default",.referencePreset))
            let color = CGColorSpace(name:CGColorSpace.displayP3)!
            let context = CIContext(mtlDevice:device)
            for (name,settings) in profiles {
                let cb=queue.makeCommandBuffer()!
                let out=renderer.encode(input,source:nil,settings:settings,hdr:false,pipelines:pipes,commandBuffer:cb)
                let blit=cb.makeBlitCommandEncoder()!
                blit.copy(from:out,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(),sourceSize:.init(width:w,height:h,depth:1),to:read,destinationSlice:0,destinationLevel:0,destinationOrigin:.init())
                blit.endEncoding();cb.commit();cb.waitUntilCompleted()
                guard cb.status == .completed else { throw cb.error ?? NSError(domain:"GPU",code:1) }
                let image=CIImage(mtlTexture:read,options:[.colorSpace:color])!.oriented(.downMirrored)
                try context.writePNGRepresentation(of:image,to:url.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:color)
                var output=pixels
                read.getBytes(&output,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
                var gradientError:Double=0,textureChange:Double=0,edgeChange:Double=0
                for y in 0..<h { for x in 0..<w { for c in 0..<3 {
                    let i=(y*w+x)*4+c
                    if y<h/3 {gradientError+=Double(abs(Float(output[i])-ideal[i]))}
                    else if y<2*h/3 {textureChange+=Double(abs(Float(output[i])-Float(pixels[i])))}
                    else {edgeChange=max(edgeChange,Double(abs(Float(output[i])-Float(pixels[i]))))}
                } } }
                print("fixture \(name): gradient MAE \(gradientError/Double(w*(h/3)*3)), textured-region mean change \(textureChange/Double(w*(h/3)*3)), strong-edge max change \(edgeChange)")
            }
            print("PNG fixture: top banded gradient, middle fine color texture, bottom true edge; \(url.path)")
            exit(0)
        } catch { fail("filter-fixtures: \(error)") }
    }

    /// Offline native-resolution image comparison; all I/O/readback is outside timed GPU work.
    static func images(_ arguments:[String]) -> Never {
        do {
            guard arguments.count>=2 else {fail("filter-images <input.png> <output-directory> [clean.png]")}
            let dir=URL(fileURLWithPath:arguments[1],isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let gpu=MTLCreateSystemDefaultDevice()!,queue=gpu.makeCommandQueue()!,context=CIContext(mtlDevice:gpu)
            let color=CGColorSpace(name:CGColorSpace.displayP3)!
            guard let raw=CIImage(contentsOf:URL(fileURLWithPath:arguments[0])) else {fail("Cannot read input")}
            let image=raw.transformed(by:CGAffineTransform(translationX:-raw.extent.minX,y:-raw.extent.minY))
            let w=Int(image.extent.width),h=Int(image.extent.height)
            guard w>0,h>0,w<=8192,h<=8192 else {fail("Image dimensions out of bench bounds")}
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:w,height:h,mipmapped:false)
            d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite,.renderTarget]
            let input=gpu.makeTexture(descriptor:d)!,read=gpu.makeTexture(descriptor:d)!
            func upload(_ img:CIImage,to texture:MTLTexture) throws {
                let cb=queue.makeCommandBuffer()!
                context.render(img,to:texture,commandBuffer:cb,bounds:image.extent,colorSpace:color)
                cb.commit();cb.waitUntilCompleted()
                if cb.status != .completed {throw cb.error ?? NSError(domain:"GPU",code:1)}
            }
            func pixels(_ t:MTLTexture)->[Half] {
                var a=[Half](repeating:0,count:w*h*4)
                t.getBytes(&a,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0);return a
            }
            try upload(image,to:input)
            var truth:[Half]?
            if arguments.count>2 {
                guard let clean=CIImage(contentsOf:URL(fileURLWithPath:arguments[2])),clean.extent.size==image.extent.size else {fail("Clean image dimensions must match")}
                try upload(clean,to:read);truth=pixels(read)
            }
            let original=pixels(input),pipes=try ArtifactFilterPipelines(device:gpu),renderer=ArtifactFilterRenderer(device:gpu)
            var profiles:[(String,ArtifactFilterSettings)]=[("input",.init())]
            var s=ArtifactFilterSettings();s.deband = .adaptive;profiles.append(("adaptive",s));s.deband = .window;profiles.append(("window",s))
            s.deband = .reference;profiles.append(("reference1",s));s.debandIterations=3;profiles.append(("reference3",s))
            s = .init();s.antiring = .directional;profiles.append(("directional",s))
            s = .init();s.chroma = .bilateral;profiles.append(("chroma",s))
            profiles.append(("reference-default",.referencePreset))
            for (name,settings) in profiles {
                let cb=queue.makeCommandBuffer()!
                let output=renderer.encode(input,source:nil,settings:settings,hdr:false,pipelines:pipes,commandBuffer:cb)
                let blit=cb.makeBlitCommandEncoder()!
                blit.copy(from:output,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(),sourceSize:.init(width:w,height:h,depth:1),to:read,destinationSlice:0,destinationLevel:0,destinationOrigin:.init())
                blit.endEncoding();cb.commit();cb.waitUntilCompleted()
                guard cb.status == .completed else {throw cb.error ?? NSError(domain:"GPU",code:1)}
                let outImage=CIImage(mtlTexture:read,options:[.colorSpace:color])!
                try context.writePNGRepresentation(of:outImage,to:dir.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:color)
                let out=pixels(read);var change=0.0,error=0.0
                for i in out.indices where i%4 != 3 {change+=Double(abs(Float(out[i])-Float(original[i])));if let truth {error+=Double(abs(Float(out[i])-Float(truth[i])))}}
                let row:[String:Any]=["profile":name,"width":w,"height":h,"mean_change":change/Double(w*h*3),"reference_mae":truth == nil ? -1:error/Double(w*h*3)]
                print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),as:UTF8.self))
            }
            exit(0)
        } catch {fail("filter-images: \(error)")}
    }

}
