import Foundation
import Metal
struct Geometry {var matrix:SIMD4<Float>;var translation:SIMD2<Float>;var viewport:SIMD2<Float>}
@main struct Probe {
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
  let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
  let shader = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Geometry {float4 matrix;float2 translation;float2 viewport;};
  struct Varying {float4 position [[position]];float2 uv;};
  vertex Varying canvasVertex(uint id [[vertex_id]],constant float4 *vertices [[buffer(0)]],constant Geometry &g [[buffer(1)]]){
   float4 v=vertices[id];float2 p=float2(g.matrix.x*v.x+g.matrix.z*v.y,g.matrix.y*v.x+g.matrix.w*v.y)+g.translation;
   Varying o;o.position=float4(p.x*2.0f/g.viewport.x-1.0f,1.0f-p.y*2.0f/g.viewport.y,0,1);o.uv=v.zw;return o;
  }
  fragment float4 canvasFragment(Varying v [[stage_in]],texture2d<float> source [[texture(0)]]){
   constexpr sampler linear(coord::pixel,address::clamp_to_edge,filter::linear);
   return source.sample(linear,v.uv*float2(source.get_width(),source.get_height()));
  }
  """#
  let library=try device.makeLibrary(source:shader,options:nil),desc=MTLRenderPipelineDescriptor()
  desc.vertexFunction=library.makeFunction(name:"canvasVertex");desc.fragmentFunction=library.makeFunction(name:"canvasFragment");desc.colorAttachments[0].pixelFormat = .rgba8Unorm
  let pipeline=try device.makeRenderPipelineState(descriptor:desc)
  for mode in ["identity","nonuniform","fractional-origin","rotation"] {
   let dir=root.appendingPathComponent(mode),doc=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String:Any]
   let m=doc["matrix"] as! [Double];var g=Geometry(matrix:SIMD4(Float(m[0]),Float(m[1]),Float(m[2]),Float(m[3])),translation:SIMD2(Float(m[4]),Float(m[5])),viewport:SIMD2(320,160))
   let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:960,height:480,mipmapped:false);descriptor.storageMode = .shared;descriptor.usage = [.renderTarget,.shaderRead]
   let dst=device.makeTexture(descriptor:descriptor)!,command=queue.makeCommandBuffer()!,pass=MTLRenderPassDescriptor()
   pass.colorAttachments[0].texture=dst;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(41.0/255,65.0/255,87.0/255,1)
   let enc=command.makeRenderCommandEncoder(descriptor:pass)!;enc.setRenderPipelineState(pipeline)
   for record in doc["records"] as! [[String:Any]] {
    let id=record["id"] as! String,w=record["width"] as! Int,h=record["height"] as! Int,f=record["used"] as! [Double]
    let sx=3*hypot(m[0],m[1]),sy=3*hypot(m[2],m[3])
    let initialX=Float(floor(f[0]+0.5)),initialY=Float(floor(f[1]+0.5)),initialR=Float(floor(f[0]+f[2]+0.5)),initialB=Float(floor(f[1]+f[3]+0.5))
    // Literal pinned cgRoundToDevicePixelsNonIdentity, after snappedIntRect.
    let dx=Float(Double(initialX)*sx).rounded(.toNearestOrAwayFromZero),dy=Float(Double(initialY)*sy).rounded(.toNearestOrAwayFromZero)
    var dr=Float(Double(initialR)*sx).rounded(.toNearestOrAwayFromZero),db=Float(Double(initialB)*sy).rounded(.toNearestOrAwayFromZero)
    if dr==dx && initialR != initialX {dr += 1}
    if db==dy && initialB != initialY {db += 1}
    let x=Float(Double(dx)/sx),y=Float(Double(dy)/sy),rr=Float(Double(dr)/sx),bb=Float(Double(db)/sy)
    let r=x+(rr-x),b=y+(bb-y)
    let vertices:[SIMD4<Float>]=[SIMD4(x,y,0,0),SIMD4(r,y,1,0),SIMD4(x,b,0,1),SIMD4(r,y,1,0),SIMD4(r,b,1,1),SIMD4(x,b,0,1)]
    let sd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:w,height:h,mipmapped:false);sd.storageMode = .shared;sd.usage = .shaderRead;let src=device.makeTexture(descriptor:sd)!
    let rgba=try Data(contentsOf:dir.appendingPathComponent("source-native-\(id).rgba"));rgba.withUnsafeBytes{src.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
    vertices.withUnsafeBytes{enc.setVertexBytes($0.baseAddress!,length:$0.count,index:0)};enc.setVertexBytes(&g,length:MemoryLayout<Geometry>.stride,index:1);enc.setFragmentTexture(src,index:0);enc.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
   }
   enc.endEncoding();command.commit();command.waitUntilCompleted();if let error=command.error{throw error}
   var pixels=Data(count:960*480*4);pixels.withUnsafeMutableBytes{dst.getBytes($0.baseAddress!,bytesPerRow:3840,from:MTLRegionMake2D(0,0,960,480),mipmapLevel:0)}
   try pixels.write(to:out.appendingPathComponent(mode+".rgba"));let ref=try Data(contentsOf:dir.appendingPathComponent("web-live-320.rgba"));var count=0,maxDelta=0
   for i in stride(from:0,to:pixels.count,by:4){var d=0;for c in 0..<4{d=max(d,abs(Int(pixels[i+c])-Int(ref[i+c])))};count += d>0 ? 1:0;maxDelta=max(maxDelta,d)}
   print(mode,count,maxDelta)
  }
 }
}
