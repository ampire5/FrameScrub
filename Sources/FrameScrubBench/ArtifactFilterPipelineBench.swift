import Foundation
import CoreImage
import Metal
import FrameScrubCore

/// Actual DisplayScaler path at the user's physical 6K resolution. Serial GPU submissions.
enum ArtifactFilterPipelineBench {
    static func main() -> Never {
        do {
            let gpu=MTLCreateSystemDefaultDevice()!,queue=gpu.makeCommandQueue()!,context=CIContext(mtlDevice:gpu)
            let pipes=try ArtifactFilterPipelines(device:gpu),color=CGColorSpace(name:CGColorSpace.displayP3)!
            for (w,h) in [(1920,1080),(3840,2160)] {try autoreleasepool {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:w,height:h,mipmapped:false)
                d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite,.renderTarget]
                let source=gpu.makeTexture(descriptor:d)!
                var pixels=[Float16](repeating:1,count:w*h*4)
                for y in 0..<h {for x in 0..<w {
                    let v=Float((x/8)%64)/128+(x%320<160 ? 0.1:0.4),i=(y*w+x)*4
                    pixels[i]=Float16(v);pixels[i+1]=Float16(v+Float((x+y)%3)*0.008);pixels[i+2]=Float16(v)
                }}
                pixels.withUnsafeBytes {source.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*8)}
                let image=CIImage(mtlTexture:source,options:[.colorSpace:color])!
                let scaler=DisplayScaler(device:gpu,context:context)
                var profiles:[(String,ArtifactFilterSettings)]=[("off",.init()),("reference",.referencePreset)]
                var s=ArtifactFilterSettings();s.deband = .adaptive;profiles.append(("adaptive",s))
                s.deband = .window;profiles.append(("window",s));s.textureProtection=0;profiles.append(("window-unprotected",s))
                s = .init();s.chroma = .bilateral;profiles.append(("chroma3",s))
                s = .init();s.antiring = .edge;profiles.append(("post-antiring",s))
                s.deband = .window;s.chroma = .bilateral;s.chromaStrength=0.35;profiles.append(("combined",s))
                s.comparison = .split;profiles.append(("combined-split",s));s.comparison = .changes;profiles.append(("combined-changes",s))
                for (name,settings) in profiles {
                    var samples=[Double]()
                    for i in 0..<23 {
                        let cb=queue.makeCommandBuffer()!
                        _ = scaler.scaled(image,to:CGSize(width:6144,height:3456),mode:.metalfx,sharpen:0,hdr:false,artifactSettings:settings,artifactPipelines:pipes,commandBuffer:cb)
                        cb.commit();cb.waitUntilCompleted()
                        guard cb.status == .completed else {throw cb.error ?? NSError(domain:"GPU",code:1)}
                        if i>=3 {samples.append((cb.gpuEndTime-cb.gpuStartTime)*1000)}
                    }
                    let sorted=samples.sorted()
                    let row:[String:Any]=["profile":name,"source":"\(w)x\(h)","output":"6144x3456","gpu_median_ms":sorted[10],"gpu_p95_ms":sorted[18],"filter_scratch_bytes":scaler.artifactScratchBytes,"status":scaler.artifactStatus,"scaler":scaler.statusText]
                    print(String(decoding:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),as:UTF8.self))
                }
            }}
            exit(0)
        } catch {fail("filters-pipeline: \(error)")}
    }
}
