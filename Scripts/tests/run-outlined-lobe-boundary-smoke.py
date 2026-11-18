#!/usr/bin/env python3
"""Focused merge-veto raster contracts; no erasure ownership assertion."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR/NativeOutlinedLobeProof.swift"
FIXTURE = 'import Foundation\nimport CoreGraphics\nfunc image(_ actualHeight:Int,_ open:Bool,_ extraContact:Bool)->CGImage {\n let c=CGContext(data:nil,width:320,height:actualHeight,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!\n c.translateBy(x:0,y:CGFloat(actualHeight));c.scaleBy(x:1,y:-1)\n c.setFillColor(gray:0.1,alpha:1);c.fill(CGRect(x:0,y:0,width:320,height:actualHeight));c.setStrokeColor(gray:1,alpha:1);c.setLineWidth(4)\n c.beginPath();c.move(to:CGPoint(x:20,y:25));c.addLine(to:CGPoint(x:140,y:25));c.addLine(to:CGPoint(x:155,y:85));c.addLine(to:CGPoint(x:180,y:25));c.addLine(to:CGPoint(x:300,y:25));c.addLine(to:CGPoint(x:300,y:265));c.addLine(to:CGPoint(x:180,y:265));c.addLine(to:CGPoint(x:165,y:205));c.addLine(to:CGPoint(x:130,y:285));c.addLine(to:CGPoint(x:20,y:285));if !open {c.closePath()};c.strokePath()\n if extraContact {c.beginPath();c.move(to:CGPoint(x:300,y:200));c.addLine(to:CGPoint(x:270,y:300));c.strokePath()}\n return c.makeImage()!\n}\nlet a=CGRect(x:45,y:55,width:100,height:180),b=CGRect(x:190,y:55,width:85,height:180)\nvar count=0\nfor reverse in [false,true] {for kind in 0..<4 {\n let im=image(kind==1 ? 340:280,kind==2,kind==3)\n let accepted=NativeOutlinedLobeProof.inspect(image:im,first:reverse ? b:a,second:reverse ? a:b,glyph:30) != nil\n print(kind,reverse,accepted)\n precondition(accepted == (kind==0),"kind \\(kind)");count+=1\n}}\nprint("PASS",count,"actual-frame vs ROI-edge/open/art-contact contracts")\n'
with tempfile.TemporaryDirectory(prefix="aidoku-lobe-boundary-") as directory:
    work = Path(directory)
    main = work / "main.swift"
    main.write_text(FIXTURE)
    binary = work / "probe"
    subprocess.run(["swiftc", "-O", str(SOURCE), str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
