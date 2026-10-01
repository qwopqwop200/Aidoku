#!/usr/bin/env python3
"""Native macOS PDF/layer compositor checks against extracted production policies."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = r'''
import Foundation
import CoreGraphics
import ImageIO
@main struct Check {
static func main() throws {
let size=HostRenderGeometry.backgroundPixelSize(for:CGSize(width:6000,height:4000)); assert(size == CGSize(width:2449,height:1632))
let viewport=try HostRenderGeometry.parseViewport("430x932");assert(viewport == CGSize(width:430,height:932))
let frame=HostRenderGeometry.displayRect(imageSize:CGSize(width:100,height:100),viewport:CGSize(width:430,height:932)); assert(frame == CGRect(x:0,y:251,width:430,height:430))
let ctx=CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:[0,0,1,1])!);ctx.fill(CGRect(x:0,y:0,width:100,height:100))
ctx.setFillColor(CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:[1,0,0,1])!);ctx.fill(CGRect(x:0,y:80,width:100,height:20));let image=ctx.makeImage()!
let data=NSMutableData();var media=CGRect(x:0,y:0,width:100,height:100);let consumer=CGDataConsumer(data:data)!;let pdf=CGContext(consumer:consumer,mediaBox:&media,nil)!;pdf.beginPDFPage(nil);pdf.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1));pdf.fill(media);pdf.endPDFPage();pdf.closePDF()
let layers=HostProductionExporter.ExportLayers(masks:[],surfaces:[],paintBounds:[[10,10,20,20]],sourceRestorations:[[10,10,5,5]])
let out=try HostExportCompositor.composite(image:image,layers:layers,typography:data as Data,displayRect:media,size:media.size)
let outctx=CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;outctx.draw(out,in:media)
let bytes=outctx.data!.assumingMemoryBound(to:UInt8.self)
func rgb(_ x:Int,_ y:Int)->[UInt8]{let i=y*400+x*4;return [bytes[i],bytes[i+1],bytes[i+2]]}
assert(rgb(0,0)==[255,0,0],"top orientation: \(rgb(0,0))")
assert(rgb(0,99)==[0,0,255],"bottom orientation")
assert(rgb(20,20)[0]<10 && rgb(20,20)[1]>240 && rgb(20,20)[2]<10,"PDF clipping placement: \(rgb(20,20))")
assert(rgb(12,12)==[255,0,0],"restoration ordering")
assert(rgb(80,50)==[0,0,255],"outside paint bounds")
let blurLayers=HostProductionExporter.ExportLayers(masks:[],surfaces:[.init(frame:[40,10,20,50],radius:0,blur:3,saturation:1)],paintBounds:[])
let blurred=try HostExportCompositor.composite(image:image,layers:blurLayers,typography:data as Data,displayRect:media,size:media.size)
outctx.draw(blurred,in:media)
assert(rgb(0,0)==[255,0,0] && rgb(0,99)==[0,0,255],"backdrop touched outside crop")
assert(rgb(50,20)[0]>20 && rgb(50,20)[2]>20,"backdrop did not blur source transition")
let maskData=NSMutableData();let maskDestination=CGImageDestinationCreateWithData(maskData,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(maskDestination,image,nil);assert(CGImageDestinationFinalize(maskDestination))
let maskLayers=HostProductionExporter.ExportLayers(masks:[.init(frame:[40,40,20,20],opacity:1,png:"data:image/png;base64,"+(maskData as Data).base64EncodedString())],surfaces:[],paintBounds:[])
let masked=try HostExportCompositor.composite(image:image,layers:maskLayers,typography:data as Data,displayRect:media,size:media.size)
outctx.draw(masked,in:media)
assert(rgb(50,40)[0]>240 && rgb(50,40)[2]<10,"mask frame or orientation")
assert(rgb(50,58)[0]<10 && rgb(50,58)[2]>240,"mask lower orientation")
assert(rgb(80,50)==[0,0,255],"mask touched outside frame")
// The native path shares repair CGImages; the portable layer schema remains replayable.
let patchContext=CGContext(data:nil,width:40,height:40,bitsPerComponent:8,bytesPerRow:160,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
patchContext.setFillColor(CGColor(red:0.2,green:0.6,blue:0.4,alpha:0.5))
patchContext.fill(CGRect(x:0,y:0,width:40,height:20))
patchContext.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1))
patchContext.fill(CGRect(x:0,y:20,width:20,height:20))
let patch=patchContext.makeImage()!
let rendered=NativeTranslationRenderer.Result(sourcePatches:[.init(image:patch,rect:CGRect(x:35,y:30,width:40,height:40))],
    paintBounds:[CGRect(x:40,y:40,width:10,height:10)],sourceRestorationRects:[CGRect(x:40,y:40,width:5,height:5)])
let direct=try HostExportCompositor.composite(image:image,rendered:rendered,typography:data as Data,displayRect:media,size:media.size)
let persisted=try HostExportCompositor.layers(for:rendered)
let replayed=try JSONDecoder().decode(HostProductionExporter.ExportLayers.self,from:JSONEncoder().encode(persisted))
assert(replayed.masks.count==1 && replayed.masks[0].png.hasPrefix("data:image/png;base64,"),"portable layer schema changed")
let decoded=try HostExportCompositor.composite(image:image,layers:replayed,typography:data as Data,displayRect:media,size:media.size)
func pixels(_ image:CGImage)->[UInt8]{
    outctx.clear(media);outctx.draw(image,in:media)
    return Array(UnsafeBufferPointer(start:bytes,count:40000))
}
let directPixels=pixels(direct), decodedPixels=pixels(decoded)
let maximumDifference=zip(directPixels,decodedPixels).map{abs(Int($0)-Int($1))}.max()!
assert(maximumDifference<=1,"native patch changed alpha/color/orientation: max difference \(maximumDifference)")
// Native inputs retain the same per-patch bounds even though no PNG decoder runs.
let oversized=CGContext(data:nil,width:8193,height:1,bitsPerComponent:8,bytesPerRow:8193*4,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
let invalid=NativeTranslationRenderer.Result(sourcePatches:[.init(image:oversized,rect:media)],paintBounds:[],sourceRestorationRects:[])
do {
    _=try HostExportCompositor.composite(image:image,rendered:invalid,typography:data as Data,displayRect:media,size:media.size)
    assertionFailure("oversized native repair accepted")
} catch { assert((error as NSError).localizedDescription=="Invalid native source repair dimensions") }
print("Host geometry, PDF compositor and direct native patch fixtures passed; max byte difference: \(maximumDifference)")
}}
'''


def shared_sources():
    background = (ROOT / "Aidoku/Features/Reader/Translation/ReaderTranslationBackgroundImage.swift").read_text()
    reader = (ROOT / "Aidoku/Core/Translation/ReaderTranslationService.swift").read_text()
    exporter = (ROOT / "Aidoku/Features/Reader/Translation/ReaderTranslationImageExporter.swift").read_text()
    def slice_text(text, start, end):
        begin = text.index(start)
        return text[begin:text.index(end, begin)]
    return (
        "import Foundation\nimport CoreGraphics\n"
        + slice_text(background, "enum ReaderTranslationBackgroundImage {", "    static func prepare(") + "}\n"
        + slice_text(reader, "enum ReaderTranslationGeometry {", "@available(iOS 18.0, *)")
        + "enum HostProductionExportSizing {\n"
        + slice_text(exporter, "    static func outputSize(for pixels: CGSize)", "    static func render(") + "}\n"
        + "enum NativeTranslationRenderer {\n"
        + "struct SourcePatch {let image: CGImage; let rect: CGRect}\n"
        + "struct Result {let sourcePatches: [SourcePatch]; let paintBounds: [CGRect]; let sourceRestorationRects: [CGRect]}\n}\n"
        + "enum HostProductionExporter {\n"
        + slice_text(exporter, "    struct ExportLayers:", "    /// Core Image contexts") + "}\n"
    )


def main():
    with tempfile.TemporaryDirectory(prefix="aidoku-host-compositor-") as directory:
        temporary = Path(directory)
        (temporary / "Shared.swift").write_text(shared_sources())
        (temporary / "Check.swift").write_text(FIXTURE)
        # Do not enable -O: the fixture deliberately uses Swift's assert checks.
        subprocess.run([
            "/usr/bin/xcrun", "swiftc", "-parse-as-library", str(temporary / "Shared.swift"),
            str(ROOT / "Scripts/image-translation/HostRenderGeometry.swift"),
            str(ROOT / "Scripts/image-translation/HostExportCompositor.swift"),
            str(temporary / "Check.swift"), "-o", str(temporary / "check"),
        ], check=True)
        subprocess.run([str(temporary / "check")], check=True)


if __name__ == "__main__":
    main()
