/// Independent Metal implementations of local-range limiting, thresholded debanding and
/// luma-guided chroma filtering. Algorithm references/limits: docs/bench/player-filter-lab.md.
enum ArtifactFilterKernels {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct P {float strength;float threshold;float radius;float dither;uint mode;uint pass;uint comparison;float protection;};
    float lum(float3 v){return dot(v,float3(.2289746,.6917385,.0792869));}
    int2 bound(int2 q, uint w,uint h){return clamp(q,int2(0),int2(w-1,h-1));}
    float3 sampleAt(texture2d<float,access::read> s,int2 q){return s.read(uint2(bound(q,s.get_width(),s.get_height()))).rgb;}
    float2 chroma(float3 v){return v.rb-lum(v);}
    float3 fromChroma(float y,float2 c){float r=y+c.x,b=y+c.y;return float3(r,(y-.2289746*r-.0792869*b)/.6917385,b);}
    uint hash(uint v){v^=v>>16;v*=0x7feb352du;v^=v>>15;v*=0x846ca68bu;return v^(v>>16);}
    float random(uint v){return float(hash(v)&0xffffu)/65535.f;}
    float4 antiringValue(texture2d<float,access::read> src,texture2d<float,access::read> input,constant P& p,uint2 xy){
      float2 pos=(float2(xy)+.5f)*float2(src.get_width(),src.get_height())/float2(input.get_width(),input.get_height())-.5f;int2 b=int2(floor(pos));
      float lo=1e9f,hi=-1e9f;for(int y=0;y<2;y++)for(int x=0;x<2;x++){float v=lum(sampleAt(src,b+int2(x,y)));lo=min(lo,v);hi=max(hi,v);}
      float4 original=input.read(xy);float y=lum(original.rgb);float delta=clamp(y,lo-2.f/255.f,hi+2.f/255.f)-y;
      if(p.mode==2 && abs(delta)>1e-7f){float v[25],mn=1e9f,mx=-1e9f;for(int j=0;j<5;j++)for(int i=0;i<5;i++){float q=lum(sampleAt(src,b+int2(i*2-4,j*2-4)));v[j*5+i]=q;mn=min(mn,q);mx=max(mx,q);}
       float gx=0,gy=0,variation=0;for(int j=0;j<5;j++)for(int i=0;i<4;i++){float dx=v[j*5+i+1]-v[j*5+i],dy=v[(i+1)*5+j]-v[i*5+j];gx+=dx;gy+=dy;variation+=abs(dx)+abs(dy);}
       delta*=smoothstep(.06f,.14f,mx-mn)*smoothstep(.55f,.9f,(abs(gx)+abs(gy))/max(variation,1e-6f));}
      return float4(original.rgb+delta*p.strength,original.a);
    }
    kernel void ar(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::read> input [[texture(1)]],texture2d<float,access::write> out [[texture(2)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      out.write(antiringValue(src,input,p,xy),xy);
    }
    kernel void colorClean(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      float4 original=src.read(xy);float y=lum(original.rgb);float2 center=chroma(original.rgb),result=0;
      if(p.mode==3){float2 v[9];int n=0;for(int j=-1;j<=1;j++)for(int i=-1;i<=1;i++)v[n++]=chroma(sampleAt(src,int2(xy)+int2(i,j)));
       for(int i=1;i<9;i++){float2 value=v[i];for(int j=i;j>0;j--){float2 prev=v[j-1];v[j]=max(prev,value);value=min(prev,value);}v[0]=value;}result=v[4];
      }else{int radius=p.mode==2?2:1;float total=0;float sigmaC=.012f+.10f*p.strength;
       for(int j=-radius;j<=radius;j++)for(int i=-radius;i<=radius;i++){float3 neighbor=sampleAt(src,int2(xy)+int2(i,j));float2 c=chroma(neighbor);float dy=(lum(neighbor)-y)/.045f;float2 dc=(c-center)/sigmaC;
        float weight=exp(-.35f*float(i*i+j*j)-dy*dy-dot(dc,dc));result+=c*weight;total+=weight;}result/=max(total,1e-6f);}
      out.write(float4(fromChroma(y,mix(center,result,p.strength)),original.a),xy);
    }
    kernel void deband(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      float4 original=src.read(xy);uint seed=xy.x+xy.y*16381u+p.pass*92821u;float angle=random(seed)*6.2831853f;float distance=1.f+random(seed+71u)*p.radius;
      int2 a=int2(round(float2(cos(angle),sin(angle))*distance));int2 b=int2(-a.y,a.x);
      float3 x=sampleAt(src,int2(xy)+a),y=sampleAt(src,int2(xy)-a),z=sampleAt(src,int2(xy)+b),w=sampleAt(src,int2(xy)-b);float3 avg=(x+y+z+w)*.25f;
      float error=max(max(length(x-original.rgb),length(y-original.rgb)),max(length(z-original.rgb),length(w-original.rgb)));
      float blend=(1.f-smoothstep(p.threshold*.6f,p.threshold,error))*p.strength;
      out.write(float4(mix(original.rgb,avg,blend),original.a),xy);
    }
    // Local opposing gradients cancel on a plane or a single monotone step,
    // but retain alternating luma/chroma texture. All channels protect colored details.
    float textureActivity(texture2d<float,access::read> src,int2 q){
      float3 gx=0,gy=0,ax=0,ay=0;
      for(int j=-1;j<=1;j++)for(int i=-1;i<1;i++){
        float3 dx=sampleAt(src,q+int2(i+1,j))-sampleAt(src,q+int2(i,j));
        float3 dy=sampleAt(src,q+int2(j,i+1))-sampleAt(src,q+int2(j,i));
        gx+=dx;gy+=dy;ax+=abs(dx);ay+=abs(dy);
      }
      float3 canceled=max(float3(0),(ax+ay-abs(gx)-abs(gy))/12.f);
      return max(canceled.r,max(canceled.g,canceled.b));
    }
    float difference(float3 a,float3 b){float3 d=abs(a-b);return max(d.r,max(d.g,d.b));}
    kernel void adaptiveDeband(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      float4 original=src.read(xy);int2 q=int2(xy);
      float activity=textureActivity(src,q);
      float confidence=1.f-p.protection*smoothstep(.15f/255.f,1.f/255.f,activity);
      if(confidence<.001f){out.write(original,xy);return;}
      float3 sum=0;float maxError=0;
      // Two symmetric cardinal rings: no animated RNG or temporal history.
      // Limit each axis symmetrically at borders to avoid bending a planar gradient.
      int radius=max(1,int(round(p.radius))),inner=max(1,radius/2+1);
      for(int ring=0;ring<2;ring++){
        int r=ring==0?radius:inner;
        int rx=min(r,min(q.x,int(src.get_width())-1-q.x));
        int ry=min(r,min(q.y,int(src.get_height())-1-q.y));
        float3 a=sampleAt(src,q+int2(rx,0)),b=sampleAt(src,q-int2(rx,0));
        float3 c=sampleAt(src,q+int2(0,ry)),d=sampleAt(src,q-int2(0,ry));
        sum+=a+b+c+d;
        maxError=max(maxError,max(max(difference(a,original.rgb),difference(b,original.rgb)),max(difference(c,original.rgb),difference(d,original.rgb))));
      }
      float edgeGate=1.f-smoothstep(p.threshold*.6f,p.threshold,maxError);
      out.write(float4(mix(original.rgb,sum*.125f,p.strength*confidence*edgeGate),original.a),xy);
    }
    // A small constrained directional experiment inspired by CDEF's principles,
    // not a normative AV1 filter (no codec strength signaling or reference buffers).
    float3 constrainedDifference(float3 neighbor,float3 center,float threshold){
      float3 d=neighbor-center,a=abs(d);
      float gate=1.f-smoothstep(threshold*.8f,threshold,difference(neighbor,center));
      return sign(d)*min(a,max(float3(0),threshold-a*.75f))*gate;
    }
    kernel void directional(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      float4 original=src.read(xy);int2 q=int2(xy);
      const int2 axes[4]={int2(1,0),int2(1,1),int2(0,1),int2(-1,1)};
      float best=1e9f;int direction=0;
      for(int k=0;k<4;k++){
        float cost=difference(sampleAt(src,q+axes[k]),original.rgb)+difference(sampleAt(src,q-axes[k]),original.rgb);
        if(cost<best){best=cost;direction=k;}
      }
      float3 correction=0;
      for(int signum=-1;signum<=1;signum+=2){
        correction+=4.f*constrainedDifference(sampleAt(src,q+axes[direction]*signum),original.rgb,p.threshold);
        correction+=2.f*constrainedDifference(sampleAt(src,q+axes[direction]*signum*2),original.rgb,p.threshold);
        correction+=constrainedDifference(sampleAt(src,q+axes[(direction+1)%4]*signum),original.rgb,p.threshold);
        correction+=constrainedDifference(sampleAt(src,q+axes[(direction+3)%4]*signum),original.rgb,p.threshold);
      }
      out.write(float4(original.rgb+correction*(p.strength/16.f),original.a),xy);
    }
    kernel void windowDeband(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      float4 original=src.read(xy);int2 q=int2(xy);
      float confidence=1.f-p.protection*smoothstep(.15f/255.f,1.f/255.f,textureActivity(src,q));
      if(confidence<.001f){out.write(original,xy);return;}
      int radius=max(1,int(round(p.radius))),rx=0,ry=0;bool accepted=false;
      // At most seven halvings for the configured 1..64 radius; bounded work.
      for(int attempt=0;attempt<7;attempt++){
        rx=min(radius,min(q.x,int(src.get_width())-1-q.x));
        ry=min(radius,min(q.y,int(src.get_height())-1-q.y));
        float error=0;
        for(int j=-1;j<=1;j++)for(int i=-1;i<=1;i++){
          if(i==0 && j==0)continue;
          error=max(error,difference(sampleAt(src,q+int2(i*rx,j*ry)),original.rgb));
        }
        if(error<p.threshold*.9f){accepted=true;break;}
        if(radius==1)break;
        radius=max(1,radius/2);
      }
      if(!accepted){out.write(original,xy);return;}
      float3 sum=0;float error=0;
      for(int j=0;j<4;j++)for(int i=0;i<4;i++){
        int2 delta=int2(round(float2(float(i)*2.f/3.f-1.f,float(j)*2.f/3.f-1.f)*float2(rx,ry)));
        float3 v=sampleAt(src,q+delta);sum+=v;error=max(error,difference(v,original.rgb));
      }
      float gate=1.f-smoothstep(p.threshold*.6f,p.threshold,error);
      out.write(float4(mix(original.rgb,sum/16.f,p.strength*confidence*gate),original.a),xy);
    }
    kernel void changes(texture2d<float,access::read> original [[texture(0)]],texture2d<float,access::read> processed [[texture(1)]],texture2d<float,access::write> out [[texture(2)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;
      float4 base=original.read(xy);float heat=clamp(difference(base.rgb,processed.read(xy).rgb)*255.f/4.f,0.f,1.f);
      out.write(float4(mix(float3(lum(base.rgb)*.2f),float3(1.f,.12f,0),heat),base.a),xy);
    }
    kernel void dither(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant P& p [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;float4 v=src.read(xy);float noise=(random(xy.x+xy.y*16381u)-.5f)*p.dither/255.f;out.write(float4(v.rgb+noise,v.a),xy);
    }
    kernel void compare(texture2d<float,access::read> original [[texture(0)]],texture2d<float,access::read> processed [[texture(1)]],texture2d<float,access::write> out [[texture(2)]],uint2 xy [[thread_position_in_grid]]){
      if(any(xy>=uint2(out.get_width(),out.get_height())))return;uint mid=out.get_width()/2;
      out.write(xy.x==mid?float4(1,1,1,1):xy.x<mid?original.read(xy):processed.read(xy),xy);
    }
    """#
}
