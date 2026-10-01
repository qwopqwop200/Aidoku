import Foundation
import CoreGraphics
let frames=[CGRect(x:39,y:135.5,width:253.5,height:85.796875),CGRect(x:284.25,y:253.46875,width:51.578125,height:182.3125)]
let space=CGColorSpace(name:CGColorSpace.sRGB)!, fill=CGColor(colorSpace:space,components:[7.0/255,9.0/255,13.0/255,1])!
let capture=try NativeTranslationPDFCapture.capture(bounds:CGRect(x:0,y:81.875,width:390,height:536.25),pixels:CGSize(width:640,height:880),deviceScale:3) { c in
 for f in frames {
 c.saveGState();c.addPath(NativeTranslationPDFCapture.roundedPath(f,radius:6,deviceScale:3));c.clip(using:.evenOdd)
 c.setAlpha((0.55*255).rounded()/255);c.setFillColor(fill);c.fill(NativeTranslationPDFCapture.snappedRect(f,deviceScale:3))
 NativeTranslationPDFCapture.drawFallbackGradient(context:c,frame:f,lightSurface:false,deviceScale:3);c.restoreGState()
 }
}
try capture.data.write(to:URL(fileURLWithPath:"build/native-render-parity/dark-export-alpha/float-device-scale.pdf"))
