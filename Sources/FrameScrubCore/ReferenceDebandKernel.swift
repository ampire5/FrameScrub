// Adapted from libplacebo src/shaders/sampling.c, pl_shader_deband.
// Source revision and license: third_party/libplacebo/SOURCE and LICENSE.
// Modified 2026-11-07: Metal texture reads, deterministic lab PRNG, strength blend;
// grain/dither remains a separate lab stage. One spatial angle/radius factor is
// reused across iterations; not bit-exact libplacebo output.
//
// This file is part of libplacebo's shader adaptation.
// This code is free software; you can redistribute it and/or modify it under
// the GNU Lesser General Public License, version 2.1 or (at your option) later.
// Distributed WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the license above.

enum ReferenceDebandKernel {
    static let source = #"""
    kernel void referenceDeband(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      float4 original=src.read(xy);float3 result=original.rgb;
      uint seed=xy.x+xy.y*16381u;
      float angle=random(seed+71u)*6.2831853f;
      float2 direction=float2(cos(angle),sin(angle));
      for(uint i=1;i<=p.mode;i++){
        float2 d=direction*(random(seed)*float(i)*p.radius);
        float3 avg=sampleAt(src,int2(xy)+int2(floor(float2(d.x,d.y)+.5f)))
                  +sampleAt(src,int2(xy)+int2(floor(float2(-d.x,d.y)+.5f)))
                  +sampleAt(src,int2(xy)+int2(floor(float2(-d.x,-d.y)+.5f)))
                  +sampleAt(src,int2(xy)+int2(floor(float2(d.x,-d.y)+.5f)));
        avg*=.25f;
        result=select(avg,result,abs(result-avg)>p.threshold/float(i));
      }
      out.write(float4(mix(original.rgb,result,p.strength),original.a),xy);
    }
    """#
}
