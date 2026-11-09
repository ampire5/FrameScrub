import Foundation
import CoreImage
import Metal
import MetalFX
import FrameScrubCore

/// Offline order ablation, one command buffer in flight; no player/UI state.
enum ArtifactFilterOrderBench {
    static func main(_ arguments:[String]) -> Never {
        do {
            guard arguments.count==3 else {fail("filter-order <input.png> <clean.png> <output-directory>")}
            let dir=URL(fileURLWithPath:arguments[2],isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let gpu=MTLCreateSystemDefaultDevice()!,queue=gpu.makeCommandQueue()!,context=CIContext(mtlDevice:gpu)
            let color=CGColorSpace(name:CGColorSpace.displayP3)!
            guard let image=CIImage(contentsOf:URL(fileURLWithPath:arguments[0])),let clean=CIImage(contentsOf:URL(fileURLWithPath:arguments[1])),image.extent==clean.extent else {fail("Images must exist and match")}
            let w=Int(image.extent.width),h=Int(image.extent.height),ow=6144,oh=3456
            guard w>0,h>0,w<=8192,h<=8192 else {fail("Input dimensions out of bounds")}
            func tex(_ width:Int,_ height:Int,_ storage:MTLStorageMode)->MTLTexture {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
                d.storageMode=storage;d.usage = [.shaderRead,.shaderWrite,.renderTarget];return gpu.makeTexture(descriptor:d)!
            }
            let input=tex(w,h,.private),truth=tex(w,h,.private),scaled=tex(ow,oh,.private),read=tex(ow,oh,.shared)
            let upload=queue.makeCommandBuffer()!
            context.render(image,to:input,commandBuffer:upload,bounds:image.extent,colorSpace:color)
            context.render(clean,to:truth,commandBuffer:upload,bounds:clean.extent,colorSpace:color)
            upload.commit();upload.waitUntilCompleted()
            guard upload.status == .completed else {throw upload.error ?? NSError(domain:"GPU",code:1)}
            let desc=MTLFXSpatialScalerDescriptor();desc.inputWidth=w;desc.inputHeight=h;desc.outputWidth=ow;desc.outputHeight=oh
            desc.colorTextureFormat = .rgba16Float;desc.outputTextureFormat = .rgba16Float;desc.colorProcessingMode = .perceptual
            guard let fx=desc.makeSpatialScaler(device:gpu) else {fail("MetalFX unsupported")}
            fx.outputTexture=scaled;fx.inputContentWidth=w;fx.inputContentHeight=h
            func readPixels(_ texture:MTLTexture) throws -> [Half] {
                let cb=queue.makeCommandBuffer()!,b=cb.makeBlitCommandEncoder()!
                b.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(),sourceSize:.init(width:ow,height:oh,depth:1),to:read,destinationSlice:0,destinationLevel:0,destinationOrigin:.init())
                b.endEncoding();cb.commit();cb.waitUntilCompleted()
                guard cb.status == .completed else {throw cb.error ?? NSError(domain:"GPU",code:1)}
                var a=[Half](repeating:0,count:ow*oh*4);read.getBytes(&a,bytesPerRow:ow*8,from:MTLRegionMake2D(0,0,ow,oh),mipmapLevel:0);return a
            }
            fx.colorTexture=truth;let cb=queue.makeCommandBuffer()!;fx.encode(commandBuffer:cb);cb.commit();cb.waitUntilCompleted()
            guard cb.status == .completed else {throw cb.error ?? NSError(domain:"GPU",code:1)}
            let reference=try readPixels(scaled)
            let renderer=ArtifactFilterRenderer(device:gpu),pipes=try ArtifactFilterPipelines(device:gpu)
            var profiles:[(String,ArtifactFilterSettings)]=[("off",.init()),("reference-default",.referencePreset)]
            var s=ArtifactFilterSettings();s.deband = .adaptive;profiles.append(("adaptive",s));s.deband = .window;profiles.append(("window",s))
            s = .init();s.chroma = .bilateral;profiles.append(("chroma",s))
            for (name,settings) in profiles {for before in [true,false] {
                if name=="off" && !before {continue}
                var samples=[Double](),result:MTLTexture=scaled
                for i in 0..<23 {
                    let cb=queue.makeCommandBuffer()!
                    if before {
                        fx.colorTexture=renderer.encode(input,source:nil,settings:settings,hdr:false,pipelines:pipes,commandBuffer:cb)
                        fx.encode(commandBuffer:cb);result=scaled
                    } else {
                        fx.colorTexture=input;fx.encode(commandBuffer:cb)
                        result=renderer.encode(scaled,source:input,settings:settings,hdr:false,pipelines:pipes,commandBuffer:cb)
                    }
                    cb.commit();cb.waitUntilCompleted()
                    guard cb.status == .completed else {throw cb.error ?? NSError(domain:"GPU",code:1)}
                    if i>=3 {samples.append((cb.gpuEndTime-cb.gpuStartTime)*1000)}
                }
                let out=try readPixels(result);var error=0.0
                for i in out.indices where i%4 != 3 {error+=Double(abs(Float(out[i])-Float(reference[i])))}
                let label=name+"-"+(before ? "before":"after")
                try context.writePNGRepresentation(of:CIImage(mtlTexture:read,options:[.colorSpace:color])!,to:dir.appendingPathComponent(label+".png"),format:.RGBA8,colorSpace:color)
                let sorted=samples.sorted()
                let row:[String:Any]=["profile":name,"order":before ? "before":"after","source":"\(w)x\(h)","output":"\(ow)x\(oh)","gpu_median_ms":sorted[10],"gpu_p95_ms":sorted[18],"reference_mae":error/Double(ow*oh*3),"scratch_bytes":renderer.allocatedBytes]
                print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),as:UTF8.self))
            }}
            exit(0)
        } catch {fail("filter-order: \(error)")}
    }
}
