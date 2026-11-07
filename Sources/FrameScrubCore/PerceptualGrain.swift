import Foundation
import Metal

/// Independent perceptual-grain experiment, not a conformant AV1/AFGS1 implementation.
/// Prepare off-main with the shared artifact pipelines. No per-frame CPU synthesis/readback.
final class PerceptualGrainPipelines {
    let mask: MTLComputePipelineState
    let apply: MTLComputePipelineState
    let fused: MTLComputePipelineState
    let templates: [MTLTexture]
    init(device: MTLDevice, library lib: MTLLibrary) throws {
        mask=try device.makeComputePipelineState(function:lib.makeFunction(name:"grainMask")!)
        apply=try device.makeComputePipelineState(function:lib.makeFunction(name:"applyGrain")!)
        fused=try device.makeComputePipelineState(function:lib.makeFunction(name:"antiringGrain")!)
        // Four independent 128² layers per style. Circular convolution avoids atlas edge seams.
        // These are authoring presets, not parameters estimated from an uncompressed original.
        let side=128, layers=4
        var textures=[MTLTexture]()
        for style in 0..<3 {
            let d=MTLTextureDescriptor();d.textureType = .type2DArray;d.pixelFormat = .r16Float
            d.width=side;d.height=side;d.arrayLength=layers;d.storageMode = .shared;d.usage = .shaderRead
            guard let t=device.makeTexture(descriptor:d) else {throw NSError(domain:"Grain",code:1)}
            for layer in 0..<layers {
                var state=UInt32(12345+layer*9301),white=[Float](repeating:0,count:side*side)
                func uniform()->Float {state ^= state<<13;state ^= state>>17;state ^= state<<5;return (Float(state & 0x00ffffff)+1)/16777217}
                for i in white.indices {white[i]=sqrt(-2*log(uniform()))*cos(2*Float.pi*uniform())}
                var field=white
                if style>0 {
                    for y in 0..<side {for x in 0..<side {
                        var sum:Float=0
                        for j in -1...1 {for i in -1...1 {
                            let weight:Float=style==1 ? (i==0 && j==0 ? 0.8 : 0.025) : Float((i==0 ? 2:1)*(j==0 ? 2:1))/16
                            sum += white[((y+j+side)%side)*side+(x+i+side)%side]*weight
                        }}
                        field[y*side+x]=sum
                    }}
                }
                let mean=field.reduce(0,+)/Float(field.count)
                let rms=sqrt(field.reduce(0){$0+($1-mean)*($1-mean)}/Float(field.count))
                var pixels=field.map{Float16(max(-3.5,min(3.5,($0-mean)/rms)))}
                pixels.withUnsafeMutableBytes {t.replace(region:MTLRegionMake2D(0,0,side,side),mipmapLevel:0,slice:layer,withBytes:$0.baseAddress!,bytesPerRow:side*2,bytesPerImage:side*side*2)}
            }
            textures.append(t)
        }
        textures.append(try GrainTemplateBank.load("av1", device:device))
        textures.append(try GrainTemplateBank.load("particles", device:device))
        templates=textures
    }
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct G {float amount,size,base,adaptation;uint seed;};
    float maxc(float3 v){return max(v.r,max(v.g,v.b));}
    float3 at(texture2d<float,access::read> t,int2 p){return t.read(uint2(clamp(p,int2(0),int2(t.get_width()-1,t.get_height()-1)))).rgb;}
    // Opposing differences separate monotonic structure from oscillating luma/chroma detail.
    float2 activity(texture2d<float,access::read> t,int2 q){
      float3 c=at(t,q),a=c-at(t,q-int2(1,0)),b=at(t,q+int2(1,0))-c;
      float3 d=c-at(t,q-int2(0,1)),e=at(t,q+int2(0,1))-c;
      float tex=maxc(max(float3(0),(abs(a)+abs(b)+abs(d)+abs(e)-abs(a+b)-abs(d+e))*.25f));
      return float2(tex,max(maxc(abs(a+b)*.5f),maxc(abs(d+e)*.5f)));
    }
    kernel void grainMask(texture2d<float,access::read> original [[texture(0)]],texture2d<float,access::read> cleaned [[texture(1)]],texture2d<float,access::write> mask [[texture(2)]],constant G& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(mask.get_width(),mask.get_height())))return;
      int2 q=int2(xy)*4+2;float before=0,after=0,edge=0;
      for(int j=-2;j<2;j++)for(int i=-2;i<2;i++){
        float2 a=activity(original,q+int2(i,j)),b=activity(cleaned,q+int2(i,j));
        before=max(before,a.x);after=max(after,b.x);edge=max(edge,max(a.y,b.y));
      }
      float removed=smoothstep(.1f/255.f,1.f/255.f,max(0.f,before-after));
      float preserved=max(after,before*(1.f-.65f*removed));
      float protection=(1.f-smoothstep(.25f/255.f,1.2f/255.f,preserved))*(1.f-smoothstep(4.f/255.f,10.f/255.f,edge));
      float weight=mix(1.f,(p.base+(1.f-p.base)*removed)*protection,p.adaptation);
      mask.write(float4(weight),xy);
    }
    uint gh(uint v){v^=v>>16;v*=0x7feb352du;v^=v>>15;v*=0x846ca68bu;return v^(v>>16);}
    float tile(texture2d_array<float,access::sample> t,int2 block,float2 local,uint seed){
      constexpr sampler sm(coord::normalized,address::repeat,filter::linear);
      uint h=gh(as_type<uint>(block.x)*92821u+as_type<uint>(block.y)*68917u+seed);
      uint mask=t.get_width()-1u,bits=t.get_width()==64u ? 6u:7u;
      return t.sample(sm,(local+float2(h&mask,(h>>bits)&mask)+.5f)/float(t.get_width()),(h>>(2u*bits))&(t.get_array_size()-1u)).r;
    }
    float pair(float a,float b,float t){float x=1.f-t;return (a*x+b*t)*rsqrt(x*x+t*t);}
    float grain(texture2d_array<float,access::sample> tex,float2 pos,uint seed){
      int2 block=int2(floor(pos/64.f));float2 local=pos-float2(block)*64.f;
      float v=tile(tex,block,local,seed);float tx=smoothstep(0.f,4.f,local.x),ty=smoothstep(0.f,4.f,local.y);
      if(local.x<4.f)v=pair(tile(tex,block-int2(1,0),local+float2(64,0),seed),v,tx);
      if(local.y<4.f){float upper=tile(tex,block-int2(0,1),local+float2(0,64),seed);
        if(local.x<4.f)upper=pair(tile(tex,block-int2(1,1),local+float2(64,64),seed),upper,tx);
        v=pair(upper,v,ty);}
      return v;
    }
    float4 grainValue(float4 v,texture2d<float,access::sample> mask,texture2d_array<float,access::sample> templ,constant G& p,uint2 xy,uint2 size){
      constexpr sampler sm(coord::normalized,address::clamp_to_edge,filter::linear);
      float y=dot(v.rgb,float3(.2289746,.6917385,.0792869));
      float response=smoothstep(.02f,.10f,y)*(1.f-smoothstep(.85f,.98f,y));
      float weight=mask.sample(sm,(float2(xy)+.5f)/float2(size)).r;
      float n=grain(templ,float2(xy)/p.size,p.seed)*p.amount/255.f*weight*response;
      float room=max(0.f,min(min(v.r,min(v.g,v.b)),1.f-maxc(v.rgb)));
      // Limit symmetrically: avoid a clipping-induced brightness bias near gamut boundaries.
      n=clamp(n,-room,room);return float4(v.rgb+n,v.a);
    }
    kernel void applyGrain(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::sample> mask [[texture(1)]],texture2d_array<float,access::sample> templ [[texture(2)]],texture2d<float,access::write> out [[texture(3)]],constant G& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      out.write(grainValue(src.read(xy),mask,templ,p,xy,uint2(out.get_width(),out.get_height())),xy);
    }
    kernel void antiringGrain(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::read> input [[texture(1)]],texture2d<float,access::sample> mask [[texture(2)]],texture2d_array<float,access::sample> templ [[texture(3)]],texture2d<float,access::write> out [[texture(4)]],constant P& ar [[buffer(0)]],constant G& p [[buffer(1)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      // Preserve the separate AR texture's FP16 boundary within GPU rounding tolerance.
      float4 v=float4(half4(antiringValue(source,input,ar,xy)));
      out.write(grainValue(v,mask,templ,p,xy,uint2(out.get_width(),out.get_height())),xy);
    }
    """#
}

/// Per-scaler bounded buffers. Serial encoding contract, retained by each submitted command buffer.
public final class PerceptualGrainRenderer {
    private let device: MTLDevice
    private var mask: MTLTexture?
    private var output: MTLTexture?
    private var sharpenInput: MTLTexture?
    public private(set) var status = "Grain: off"
    public var allocatedBytes: Int { [mask,output,sharpenInput].compactMap{$0}.reduce(0){$0+$1.allocatedSize} }
    private struct Parameters {var amount:Float;var size:Float;var base:Float;var adaptation:Float;var seed:UInt32}
    public init(device: MTLDevice) { self.device=device }
    public func clear() {mask=nil;output=nil;sharpenInput=nil;status="Grain: off"}
    private func texture(_ w:Int,_ h:Int,_ format:MTLPixelFormat)->MTLTexture? {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
        d.storageMode = .private;d.usage=[.shaderRead,.shaderWrite,.renderTarget];return device.makeTexture(descriptor:d)
    }
    private func params(_ s:ArtifactFilterSettings,_ seed:UInt32=0)->Parameters {
        .init(amount:Float(s.grainAmount*s.strength),size:Float(s.grainSize),base:Float(s.grainBase),adaptation:Float(s.grainAdaptation),seed:seed)
    }
    public func prepareMask(original:MTLTexture,cleaned:MTLTexture,settings:ArtifactFilterSettings,pipelines:ArtifactFilterPipelines,commandBuffer:MTLCommandBuffer)->Bool {
        let w=(original.width+3)/4,h=(original.height+3)/4
        if mask?.width != w || mask?.height != h {mask=texture(w,h,.r16Float)}
        guard let mask,let e=commandBuffer.makeComputeCommandEncoder() else {status="Grain: mask failed";return false}
        e.setComputePipelineState(pipelines.grain.mask);e.setTexture(original,index:0);e.setTexture(cleaned,index:1);e.setTexture(mask,index:2)
        var p=params(settings);e.setBytes(&p,length:MemoryLayout<Parameters>.stride,index:0)
        e.dispatchThreads(.init(width:w,height:h,depth:1),threadsPerThreadgroup:.init(width:16,height:8,depth:1));e.endEncoding();status="Grain: ready";return true
    }
    /// Only allocated if the existing sharpen stage needs materializing before grain.
    func staging(width:Int,height:Int)->MTLTexture? {
        if sharpenInput?.width != width || sharpenInput?.height != height {sharpenInput=texture(width,height,.rgba16Float)}
        return sharpenInput
    }
    /// Writes an existing post-filter target: no separate6K grain texture or pass.
    func encodeFusedAntiring(source:MTLTexture,input:MTLTexture,target:MTLTexture,settings:ArtifactFilterSettings,seed:UInt32,pipelines:ArtifactFilterPipelines,commandBuffer:MTLCommandBuffer)->Bool {
        guard let mask,target !== input,target !== source,let e=commandBuffer.makeComputeCommandEncoder() else {return false}
        struct AR {var strength:Float;var threshold:Float=0;var radius:Float=0;var dither:Float=0;var mode:UInt32;var pass:UInt32=0;var comparison:UInt32=0;var protection:Float=0}
        var ar=AR(strength:Float(settings.strength*settings.antiringStrength),mode:settings.antiring == .edge ? 2:1),p=params(settings,seed)
        e.label="Filter Lab: fused AR + grain";e.setComputePipelineState(pipelines.grain.fused)
        e.setTexture(source,index:0);e.setTexture(input,index:1);e.setTexture(mask,index:2)
        e.setTexture(pipelines.grain.templates[settings.grain.templateIndex],index:3);e.setTexture(target,index:4)
        e.setBytes(&ar,length:MemoryLayout<AR>.stride,index:0);e.setBytes(&p,length:MemoryLayout<Parameters>.stride,index:1)
        e.dispatchThreads(.init(width:input.width,height:input.height,depth:1),threadsPerThreadgroup:.init(width:16,height:8,depth:1));e.endEncoding()
        output=nil;sharpenInput=nil;status="Grain: \(settings.grain.rawValue)";return true
    }
    public func encode(_ input:MTLTexture,settings:ArtifactFilterSettings,seed:UInt32,pipelines:ArtifactFilterPipelines,commandBuffer:MTLCommandBuffer)->MTLTexture {
        guard settings.grain != .off,settings.grainAmount>0,settings.enabled,settings.strength>0 else {clear();return input}
        if output?.width != input.width || output?.height != input.height {output=texture(input.width,input.height,.rgba16Float)}
        guard let mask,let output,let e=commandBuffer.makeComputeCommandEncoder() else {status="Grain: output failed";return input}
        e.setComputePipelineState(pipelines.grain.apply)
        e.setTexture(input,index:0);e.setTexture(mask,index:1)
        e.setTexture(pipelines.grain.templates[settings.grain.templateIndex],index:2);e.setTexture(output,index:3)
        var p=params(settings,seed);e.setBytes(&p,length:MemoryLayout<Parameters>.stride,index:0)
        e.dispatchThreads(.init(width:input.width,height:input.height,depth:1),threadsPerThreadgroup:.init(width:16,height:8,depth:1));e.endEncoding()
        status="Grain: \(settings.grain.rawValue)";return output
    }
}
