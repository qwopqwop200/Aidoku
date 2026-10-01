import Foundation
import Metal
struct Frame { var origin:SIMD2<Int32>;var size:SIMD2<Int32>;var sampleScale:SIMD2<Float>;var lod:Float }
@main struct Probe {
 static func main()throws {
  let directory=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2]);let opaque=CommandLine.arguments[3]=="opaque"
  let document=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String:Any]
  let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
  let source = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Frame {int2 origin;int2 size;float2 sampleScale;float lod;};
  kernel void paint(texture2d<float,access::sample> src [[texture(0)]],texture2d<float,access::read_write> dst [[texture(1)]],constant Frame &f [[buffer(0)]],uint2 p [[thread_position_in_grid]]){
   if(p.x>=dst.get_width()||p.y>=dst.get_height())return;int2 q=int2(p)-f.origin;if(any(q<0)||any(q>=f.size))return;
   constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
   float4 value=src.sample(s,(float2(q)+0.5f)/float2(f.size)*f.sampleScale,level(f.lod));
   dst.write(value+dst.read(p)*(1.0f-value.a),p);
  }
  """#
  let library=try device.makeLibrary(source:source,options:nil),pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"paint")!)
  for mode in ["zero","max","min","mean","half","one"] {
   let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:960,height:480,mipmapped:false);d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
   let dst=device.makeTexture(descriptor:d)!
   var background=Data(count:960*480*4)
   if opaque {for i in stride(from:0,to:background.count,by:4){background[i]=41;background[i+1]=65;background[i+2]=87;background[i+3]=255}}
   background.withUnsafeBytes{dst.replace(region:MTLRegionMake2D(0,0,960,480),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:3840)}
   for record in document["records"] as! [[String:Any]] {
    let id=record["id"] as! String,w=record["width"] as! Int,h=record["height"] as! Int,b=record["used"] as! [Double]
    let pixels=try Data(contentsOf:directory.appendingPathComponent("source-native-\(id).rgba"))
    let pw=(w+1)/2*2,ph=(h+1)/2*2
    let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:pw,height:ph,mipmapped:true);desc.storageMode = .shared;desc.usage = .shaderRead
    let src=device.makeTexture(descriptor:desc)!
    var padded=Data(count:pw*ph*4)
    for row in 0..<h {padded.replaceSubrange((row*pw*4)..<(row*pw*4+w*4),with:pixels[(row*w*4)..<((row+1)*w*4)])}
    padded.withUnsafeBytes{src.replace(region:MTLRegionMake2D(0,0,pw,ph),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:pw*4)}
    let command=queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!;blit.generateMipmaps(for:src);blit.endEncoding()
    let rw=Float(w)/Float(b[2]*3),rh=Float(h)/Float(b[3]*3);let value:Float=mode=="max" ? log2(max(rw,rh)) : mode=="min" ? log2(min(rw,rh)) : mode=="mean" ? log2((rw+rh)*0.5) : mode=="half" ? 0.5 : mode=="one" ? 1 : 0
    var f=Frame(origin:SIMD2(Int32(b[0]*3),Int32(b[1]*3)),size:SIMD2(Int32(b[2]*3),Int32(b[3]*3)),sampleScale:SIMD2(Float(w)/Float(pw),Float(h)/Float(ph)),lod:max(0,value))
    let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(pipeline);e.setTexture(src,index:0);e.setTexture(dst,index:1);e.setBytes(&f,length:MemoryLayout<Frame>.stride,index:0)
    e.dispatchThreads(MTLSize(width:960,height:480,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));e.endEncoding();command.commit();command.waitUntilCompleted();if let error=command.error{throw error}
   }
   var bytes=Data(count:960*480*4);bytes.withUnsafeMutableBytes{dst.getBytes($0.baseAddress!,bytesPerRow:3840,from:MTLRegionMake2D(0,0,960,480),mipmapLevel:0)}
   try bytes.write(to:output.appendingPathComponent(mode+".rgba"))
   let reference=try Data(contentsOf:directory.appendingPathComponent("web-live-320.rgba"));var changed=0,delta=0,maskCount=0,maskDelta=0
   for i in stride(from:0,to:bytes.count,by:4){var mismatch=false;var d=0;for j in 0..<4{d=max(d,abs(Int(bytes[i+j])-Int(reference[i+j])));mismatch = mismatch || d>0};if mismatch{changed+=1};delta=max(delta,d)
    let x=(i/4)%960,y=(i/4)/960;if x>=405 && x<678 && y>=21 && y<384{maskCount+=mismatch ? 1:0;maskDelta=max(maskDelta,d)}}
   print(mode,changed,delta,"mask",maskCount,maskDelta)
  }
 }
}
