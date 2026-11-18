import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

@main struct StrokeSmoke {
    static func main() throws {
        func selection(_ fill: [Double], _ stroke: [Double], enclosed: Double = 0) -> NativeSourceInkSelection.Selection {
            NativeSourceInkSelection.displaySelection(fill:fill,stroke:stroke,evidence:.init(
                fillPixels:1700,strokePixels:8000,fillShapePixels:1700,strokeShapePixels:4000,
                fillRepeatedTiles:30,strokeRepeatedTiles:34,fillEnclosedPixels:0,strokeEnclosedPixels:enclosed))
        }
        precondition(selection([250,250,249],[104,60,106]).color == [250,250,249], "white core lost to purple halo area")
        precondition(selection([70,73,139],[162,163,197]).color == [70,73,139], "lavender surface promoted over core")
        precondition(selection([219,76,84],[219,216,214]).color == [219,76,84], "grey halo promoted over red core")
        precondition(selection([211,96,6],[120,0,160],enclosed:800).role == "sourceStroke",
            "independently supported predominant outline should remain selectable")
        precondition(selection([253,244,215],[217,90,6]).role == "sourceStroke",
            "saturated orange emphasis outline must remain selectable")
        precondition(selection([8,138,219],[231,219,217],enclosed:800).color == [8,138,219],
            "washed halo must not replace saturated blue core")
        let w = 96, h = 64
        func fixture(_ color: UInt8, _ background: UInt8, hidden: UInt8? = nil,
                     preferred: UInt8? = nil, rgb: [UInt8]? = nil) -> (UInt8,[String:Any]) {
            var a = [UInt8](repeating:0,count:w*h), d = a
            var fill = [UInt8](repeating:0,count:w*h*4), bg = fill
            for y in 0..<h { for x in 0..<w {
                let i = y*w+x
                let glyph = (20..<40).contains(x) && (18..<46).contains(y)
                    && (x < 25 || x >= 35 || (29..<35).contains(y))
                let halo = (15..<45).contains(x) && (13..<51).contains(y)
                a[i] = glyph ? 255 : 0; d[i] = halo ? 255 : 0
                for c in 0..<3 {
                    fill[i*4+c] = glyph ? (rgb?[c] ?? color) : 0
                    bg[i*4+c] = halo ? (hidden ?? background) : background
                }
                fill[i*4+3] = a[i]; bg[i*4+3] = 255
            }}
            return NativeRenderedStrokeSelection.select(fill:fill,alpha:a,dilated:d,background:bg,
                width:w,height:h,radius:5,preferredEndpoint:preferred)
        }
        for background: UInt8 in [0,128,255] {
            precondition(fixture(0,background).0 == 255,"black ink requires white stroke")
            precondition(fixture(255,background).0 == 0,"white ink requires black stroke")
            precondition(fixture(0,background,preferred:0).0 == 255,"bad black prior must be overridden")
            precondition(fixture(255,background,preferred:255).0 == 0,"bad white prior must be overridden")
        }
        let orange = fixture(0,180,preferred:255,rgb:[211,96,6])
        precondition(orange.0 == 255,"viable white prior lost to unstable orange contrast gain")
        precondition(orange.1["retainedViablePrior"] as? Bool == true,
            "orange regression must exercise stability guard, not a trivial white score win")
        precondition(fixture(0,180,preferred:0,rgb:[221,90,6]).0 == 255,
            "ambiguous dark chromatic ink must not depend on inconsistent upstream endpoints")
        precondition(fixture(0,180,preferred:255,rgb:[255,240,80]).0 == 0,
            "pale yellow ink must retain a separating dark outline")
        // Real small CoreText glyphs, not just a large synthetic H. Smaller
        // stems must not lose white merely because one blurred sample is weak.
        for color: [CGFloat] in [[0.86,0.35,0.02],[0.01,0.68,0.90],[0.79,0.08,0.59]] {
            for size: CGFloat in [12,20] {
                let c = CGContext(data:nil,width:220,height:60,bitsPerComponent:8,bytesPerRow:0,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                let f = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString,size,nil)
                let s = NSAttributedString(string:"미... 미안해...",attributes:[
                    NSAttributedString.Key(kCTFontAttributeName as String):f,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        CGColor(red:color[0],green:color[1],blue:color[2],alpha:1)])
                c.textPosition = CGPoint(x:8,y:25)
                CTLineDraw(CTLineCreateWithAttributedString(s),c)
                let b = CGContext(data:nil,width:220,height:60,bitsPerComponent:8,bytesPerRow:0,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                b.setFillColor(CGColor(gray:0.95,alpha:1));b.fill(CGRect(x:0,y:0,width:220,height:60))
                let result = try NativeMandatoryDisplayStroke.prepare(fill:c.makeImage()!,restored:b.makeImage()!,
                    fontOutputPixels:size,forcedEndpoint:0,recheckFinalEndpoint:true)
                precondition(result.endpoint == 255,"small chromatic text lost white surround")
            }
        }
        let first = fixture(120,10,hidden:0), second = fixture(120,10,hidden:255)
        precondition(first.0 == second.0)
        precondition((first.1["scoresBW"] as! [Double]) == (second.1["scoresBW"] as! [Double]),
            "occluded background changed selection")
        precondition(fixture(120,10).0 == 255 && fixture(120,245).0 == 0,
            "ambiguous ink must respond to visible background")
        for gray: UInt8 in [90,110,120,130,150] {
            let dark = fixture(gray,10), light = fixture(gray,245)
            print("gray",gray,"dark",dark.0,"light",light.0,"scores",dark.1["scoresBW"]!,light.1["scoresBW"]!)
        }
        // Exercise the production adapter, not just the scoring leaf.
        var ink = [UInt8](repeating:0,count:w*h*4), bg = ink
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            for c in 0..<3 { bg[i*4+c] = 220 }
            bg[i*4+3] = 255
            if (20..<50).contains(x) && (20..<40).contains(y) { ink[i*4+3] = 255 }
        }}
        let fill = try NativeMandatoryDisplayStroke.image(ink,width:w,height:h)
        let restored = try NativeMandatoryDisplayStroke.image(bg,width:w,height:h)
        let prepared = try NativeMandatoryDisplayStroke.prepare(fill:fill,restored:restored,
            fontOutputPixels:20,forcedEndpoint:0,recheckFinalEndpoint:true)
        precondition(prepared.endpoint == 255 && prepared.outwardPixels == 4)
        precondition(prepared.endpointDecision["changed"] as? Bool == true)
        let kept = try NativeMandatoryDisplayStroke.rgba(prepared.fill)
        precondition(kept.filter { $0 == 255 }.count == 600,"fill coverage changed")
        // Actual production preparation, including forced-endpoint fallback.
        for recheck in [false,true] {
          for pale: [UInt8] in [[253,253,253],[225,224,224],[254,230,198],[234,220,188],[201,191,199]] {
            for surface: [UInt8] in [[255,255,255],[150,150,150],[110,95,170],[0,0,0],[38,36,38],[35,0,55]] {
                var white = ink, surfaceBytes = bg
                for i in 0..<(w*h) {
                    for c in 0..<3 {
                        white[i*4+c] = white[i*4+3] > 0 ? pale[c] : 0
                        surfaceBytes[i*4+c] = surface[c]
                    }
                }
                let blackSurface = surface.max()! <= 56 && surface.max()! - surface.min()! <= 20
                let layer = try NativeMandatoryDisplayStroke.prepare(
                    fill:NativeMandatoryDisplayStroke.image(white,width:w,height:h),
                    restored:NativeMandatoryDisplayStroke.image(surfaceBytes,width:w,height:h),
                    fontOutputPixels:20,forcedEndpoint:255,recheckFinalEndpoint:recheck)
                precondition(layer.endpoint == (blackSurface ? 0 : 255))
                precondition(layer.endpointDecision["whiteFillOverride"] as? Bool == !blackSurface)
                precondition(layer.outwardPixels == prepared.outwardPixels)
                if recheck { precondition(layer.frame == prepared.frame) }
                let pixels = try NativeMandatoryDisplayStroke.rgba(layer.fill)
                precondition(stride(from:3,to:pixels.count,by:4).filter { pixels[$0] == 255 }.count == 600)
                for i in 0..<(pixels.count/4) where pixels[i*4+3] == 255 {
                    precondition(pixels[i*4] == (blackSurface ? pale[0] : 0))
                }
            }
          }
        }
        // Reliable source white on a high-contrast coloured surface must survive
        // the final raster adapter, not only its earlier style decision.
        let appearance: [String:Any] = ["sourceOnly":true,"fill":["rgb":[255,255,255]],
            "outline":["present":false,"probability":0.001,"widthPx":0,
                "measurementEvidence":["reliable":true,"usableRays":100]],
            "shadow":["present":false,"probability":0.0],
            "background":["representation":"observed-context-palette","insufficientObservedContext":false,
                "colors":[[128,80,126]],"observedContextWeights":[1.0]]]
        var whiteInk=ink, purple=bg
        for i in 0..<(w*h) {
            for c in 0..<3 {
                whiteInk[i*4+c]=whiteInk[i*4+3]>0 ? 255:0
                purple[i*4+c]=[UInt8(128),80,126][c]
            }
        }
        let priorFlag=ProcessInfo.processInfo.environment["AIDOKU_SOURCE_AWARE_DISPLAY_GUARD"]
        defer {
            if let priorFlag {setenv("AIDOKU_SOURCE_AWARE_DISPLAY_GUARD",priorFlag,1)}
            else {unsetenv("AIDOKU_SOURCE_AWARE_DISPLAY_GUARD")}
        }
        for enabled in [false,true] {
            setenv("AIDOKU_SOURCE_AWARE_DISPLAY_GUARD",enabled ? "1":"0",1)
            for packet in [Optional(appearance),nil] {
                let actual=try NativeMandatoryDisplayStroke.prepare(
                    fill:NativeMandatoryDisplayStroke.image(whiteInk,width:w,height:h),
                    restored:NativeMandatoryDisplayStroke.image(purple,width:w,height:h),
                    fontOutputPixels:20,outwardEm:0.035,forcedEndpoint:0,sourceAppearance:packet)
                let preserve=enabled && packet != nil
                precondition(actual.endpointDecision["sourceAbsentOutlineFillPreserved"] as? Bool == preserve)
                precondition(actual.endpointDecision["whiteFillOverride"] as? Bool == !preserve)
                let pixels=try NativeMandatoryDisplayStroke.rgba(actual.fill)
                for i in 0..<(pixels.count/4) where pixels[i*4+3]==255 {
                    precondition(pixels[i*4]==(preserve ? 255:0))
                }
                precondition(actual.outwardPixels==2)
            }
        }
        print("PASS: BW controls, invalid-prior override, orange stability guard, background sensitivity/invariance, production adapter/fill/width preservation, certified source-white retention and rollback")
    }
}
