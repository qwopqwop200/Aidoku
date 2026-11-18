#!/usr/bin/env python3
"""Synthetic raster tests for the production OCR merge colour callback."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Aidoku/Core/Translation/ReaderTranslationBalloonMerger.swift"
source = SOURCE.read_text()
start = source.index("    static func textInk(")
end = source.index("\n    private static func matching", start)
function = source[start:end]
harness = r'''import Foundation
import CoreGraphics
import CoreText
'''+ "enum Production {\n" + function + "\n}\n" + r'''
typealias RGB = (Double, Double, Double)

func gap(_ a: RGB, _ b: RGB) -> Double {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
}

func sample(background: RGB, ink: RGB, rim: RGB) -> RGB? {
    let size = 64
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    func fill(_ rect: CGRect, _ color: RGB) {
        context.setFillColor(red: color.0 / 255, green: color.1 / 255, blue: color.2 / 255, alpha: 1)
        context.fill(rect)
    }
    fill(bounds, rim)
    fill(bounds.insetBy(dx: 1, dy: 1), background)
    fill(CGRect(x: 18, y: 8, width: 13, height: 48), ink)
    return Production.textInk(in: context.makeImage()!, rect: bounds)
}

let dark: RGB = (18, 20, 24), white: RGB = (245, 247, 250), blue: RGB = (135, 186, 219)
let foreign: RGB = (110, 45, 140)
let supportedByBackground = sample(background: dark, ink: white, rim: dark)!
let supportedByInk = sample(background: dark, ink: blue, rim: blue)!
precondition(gap(supportedByBackground, white) <= 2)
precondition(gap(supportedByInk, blue) <= 2)
precondition(gap(supportedByBackground, supportedByInk) >= 100)
precondition(sample(background: dark, ink: white, rim: foreign) == nil)
var controls=0
for bg in [0.0,255.0] {
 for color in [(0.0,0.0,0.0),(255.0,255.0,255.0),(153.0,67.0,120.0),(30.0,50.0,190.0)] where gap(color,(bg,bg,bg))>=80 {
  let w=224,h=96
  let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray:bg/255,alpha:1));context.fill(CGRect(x:0,y:0,width:w,height:h))
  let attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("HiraginoSans-W6" as CFString,32,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(red:color.0/255,green:color.1/255,blue:color.2/255,alpha:1)]
  context.textPosition=CGPoint(x:15,y:32)
  CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:"国回口日",attributes:attrs)),context)
  let value=Production.textInk(in:context.makeImage()!,rect:CGRect(x:0,y:0,width:w,height:h))!
  precondition(gap(value,color)<=32)
  controls+=1
 }
}
precondition(controls == 6)
print("PASS background, ink, and unsupported rims and", controls, "authored text controls")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-text-ink-rim-") as directory:
    directory = pathlib.Path(directory)
    main = directory / "main.swift"
    binary = directory / "test"
    main.write_text(harness)
    subprocess.run(["swiftc", "-O", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
