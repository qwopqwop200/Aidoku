import Foundation
import Metal
struct Geometry {var u:SIMD4<Float>;var v:SIMD4<Float>}
@main struct Probe {
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]);let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
  let shader = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Geometry {float4 u;float4 v;};
  kernel void affineImage(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::read_write> target [[texture(1)]],constant Geometry &g [[buffer(0)]],uint2 p [[thread_position_in_grid]]){
   if(p.x>=target.get_width()||p.y>=target.get_height())return;
   float3 point=float3(float2(p)+0.5f,1.0f);
   float2 uv=float2(dot(point,g.u.xyz),dot(point,g.v.xyz));
   if(any(uv<0.0f)||any(uv>=1.0f))return;
   constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
   target.write(source.sample(linear,uv),p);
  }
  """#
  let lib=try device.makeLibrary(source:shader,options:nil),pipeline=try device.makeComputePipelineState(function:lib.makeFunction(name:"affineImage")!)
  for mode in ["identity","nonuniform","fractional-origin","rotation"] {
   let dir=root.appendingPathComponent(mode),doc=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String:Any],m=doc["matrix"] as! [Double]
   let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:960,height:480,mipmapped:false);d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite];let dst=device.makeTexture(descriptor:d)!
   var bg=Data(count:960*480*4);for i in stride(from:0,to:bg.count,by:4){bg[i]=41;bg[i+1]=65;bg[i+2]=87;bg[i+3]=255};bg.withUnsafeBytes{dst.replace(region:MTLRegionMake2D(0,0,960,480),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:3840)}
   for record in doc["records"] as! [[String:Any]] {
    let id=record["id"] as! String,w=record["width"] as! Int,h=record["height"] as! Int,f=record["used"] as! [Double]
    let sx=3*hypot(m[0],m[1]),sy=3*hypot(m[2],m[3]),ix=Float(floor(f[0]+0.5)),iy=Float(floor(f[1]+0.5)),ir=Float(floor(f[0]+f[2]+0.5)),ib=Float(floor(f[1]+f[3]+0.5))
    let dx=Float(Double(ix)*sx).rounded(.toNearestOrAwayFromZero),dy=Float(Double(iy)*sy).rounded(.toNearestOrAwayFromZero);var dr=Float(Double(ir)*sx).rounded(.toNearestOrAwayFromZero),db=Float(Double(ib)*sy).rounded(.toNearestOrAwayFromZero)
    if dx==dr && ir != ix{dr+=1};if dy==db && ib != iy{db+=1}
    let x=Float(Double(dx)/sx),y=Float(Double(dy)/sy),rw=Float(Double(dr)/sx)-x,rh=Float(Double(db)/sy)-y
    let determinant=m[0]*m[3]-m[1]*m[2],a=m[3]/determinant,b = -m[1]/determinant,c = -m[2]/determinant,e=m[0]/determinant,tx = -(a*m[4]+c*m[5]),ty = -(b*m[4]+e*m[5])
    var g=Geometry(u:SIMD4(Float(a/(3*Double(rw))),Float(c/(3*Double(rw))),Float((tx-Double(x))/Double(rw)),0),v:SIMD4(Float(b/(3*Double(rh))),Float(e/(3*Double(rh))),Float((ty-Double(y))/Double(rh)),0))
    let sd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:w,height:h,mipmapped:false);sd.storageMode = .shared;sd.usage = .shaderRead;let src=device.makeTexture(descriptor:sd)!,rgba=try Data(contentsOf:dir.appendingPathComponent("source-native-\(id).rgba"));rgba.withUnsafeBytes{src.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
    let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!;encoder.setComputePipelineState(pipeline);encoder.setTexture(src,index:0);encoder.setTexture(dst,index:1);encoder.setBytes(&g,length:MemoryLayout<Geometry>.stride,index:0);encoder.dispatchThreads(MTLSize(width:960,height:480,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted();if let error=command.error{throw error}
   }
   var pixels=Data(count:960*480*4);pixels.withUnsafeMutableBytes{dst.getBytes($0.baseAddress!,bytesPerRow:3840,from:MTLRegionMake2D(0,0,960,480),mipmapLevel:0)};try pixels.write(to:out.appendingPathComponent(mode+".rgba"))
   let ref=try Data(contentsOf:dir.appendingPathComponent("web-live-320.rgba"));var count=0,delta=0;for i in stride(from:0,to:pixels.count,by:4){var d=0;for c in 0..<4{d=max(d,abs(Int(pixels[i+c])-Int(ref[i+c])))};count += d>0 ? 1:0;delta=max(delta,d)};print(mode,count,delta)
  }
 }
}
