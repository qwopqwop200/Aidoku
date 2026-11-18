#!/usr/bin/env python3
"""Compile actual folder selection/decoding; no OCR, provider or credentials."""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Scripts/image-translation/PipelineMain.swift').read_text()
catalog = source[source.index('enum HostImageInputs {'):source.index('struct HostOptions {')]
selection = source[source.index('    func images() throws -> [URL] {'):source.index('\n}\n\nstruct HostPageResult')]
decoding = source[source.index('    static func loadImage('):source.index('    static func imageData(')]
harness = '''import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
enum HostError: Error { case message(String) }
''' + catalog + '''
struct HostOptions {
 var inputs: [URL] = []; var lists: [URL] = []; var recursive = false
 var output: URL; var limit: Int?
''' + selection + '''\n}
enum Decoder {
''' + decoding + '''\n}
func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
check(HostImageInputs.extensions.contains("jp2"),"ImageIO JPEG-2000 extension discovered dynamically")
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let folder=root.appendingPathComponent("images")
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
let ctx=CGContext(data:nil,width:16,height:12,bitsPerComponent:8,bytesPerRow:0,
 space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red:0.3,green:0.6,blue:0.8,alpha:1));ctx.fill(CGRect(x:0,y:0,width:16,height:12))
let image=ctx.makeImage()!
for (name,type) in [("page.PNG","public.png"),("page.jpg","public.jpeg"),("page.tiff","public.tiff")] {
 let dst=CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,type as CFString,1,nil)!
 CGImageDestinationAddImage(dst,image,nil);check(CGImageDestinationFinalize(dst),"encode fixture")
}
try FileManager.default.copyItem(at:folder.appendingPathComponent("page.PNG"),to:folder.appendingPathComponent("no-extension"))
try FileManager.default.copyItem(at:folder.appendingPathComponent("page.PNG"),to:folder.appendingPathComponent("unexpected.data"))
try Data("{}".utf8).write(to:folder.appendingPathComponent("metadata.json"))
try Data("broken".utf8).write(to:folder.appendingPathComponent("broken.avif"))
let nested=folder.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
try FileManager.default.copyItem(at:folder.appendingPathComponent("page.jpg"),to:nested.appendingPathComponent("child.JPEG"))
var options=HostOptions(output:root.appendingPathComponent("output"));options.inputs=[folder]
let flat=try options.images();check(flat.count==6,"all image formats, invalid AVIF and content-probed files selected; JSON excluded")
options.recursive=true;check(try options.images().count==7,"recursive collection")
options.inputs=[folder.appendingPathComponent("page.PNG"),folder.appendingPathComponent("no-extension")]
check(try options.images().count==2,"explicit input list")
let list=root.appendingPathComponent("list.json")
try JSONSerialization.data(withJSONObject:["images/page.PNG","images/page.jpg"]).write(to:list)
options.inputs=[];options.lists=[list];check(try options.images().count==2,"list collection")
for file in flat where file.lastPathComponent != "broken.avif" {
 let decoded=try Decoder.loadImage(file);check(decoded.width==16&&decoded.height==12,"real decode")
}
do { _=try Decoder.loadImage(folder.appendingPathComponent("broken.avif"));fatalError("broken AVIF must fail decode") }
catch { check(String(describing:error).contains("Cannot decode image"),"per-image decode failure") }
if CommandLine.arguments.count>2 {
 let avif=URL(fileURLWithPath:CommandLine.arguments[2]);let decoded=try Decoder.loadImage(avif)
 ctx.draw(decoded,in:CGRect(x:0,y:0,width:16,height:12));check(decoded.width>0&&decoded.height>0,"AVIF raster decode")
 print("PASS actual AVIF decode: \\(decoded.width)x\\(decoded.height)")
}
if CommandLine.arguments.count>3 {
 options.inputs=[URL(fileURLWithPath:CommandLine.arguments[3])];options.lists=[]
 let all=try options.images();check(all.count==836,"all 836 dataset images selected")
 print("PASS output_dedup selection: \\(all.count) images")
}
print("PASS PNG/JPG/TIFF, AVIF candidate/failure, uppercase, content probing, recursive folders and lists")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-input-formats-') as temporary:
    folder = Path(temporary)
    swift = folder / 'main.swift'
    swift.write_text(harness)
    subprocess.run(['swift', str(swift), str(folder), *sys.argv[1:]], check=True)
