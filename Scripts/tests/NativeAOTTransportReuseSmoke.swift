import CoreGraphics
import CoreML
import Foundation

// Compile the actual admitted-model adapter without the UI/text admission route.
// No test constructs either model class, resolves resources, predicts or loads MLModel.
enum NativeAdmittedAOTPageRoute {
    enum Failure: Error { case modelContract, allocation }
    static func image(rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        try raster(rgba,width:width,height:height)
    }
}

func check(_ value: @autoclosure () -> Bool) { precondition(value(),"AOT transport reuse contract") }
func raster(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
    let provider=CGDataProvider(data:Data(bytes) as CFData)!
    return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}

// Frozen scalar admitted-route transport, prior to sharing with the RGB route.
func historicalPrepare(_ rgba:[UInt8],_ removal:[UInt8],_ width:Int,_ height:Int,
                       _ image:MLMultiArray,_ mask:MLMultiArray) throws -> (Int,Int) {
    let side=1024,scale=min(1,Double(1024)/Double(max(width,height)))
    let sw=min(side,max(1,Int(ceil(Double(width)*scale))))
    let sh=min(side,max(1,Int(ceil(Double(height)*scale))))
    var reduced=[Float](repeating:0,count:sw*sh*3),hits=[Bool](repeating:false,count:sw*sh)
    for y in 0..<sh {
        let y0=y*height/sh,y1=min(height,((y+1)*height+sh-1)/sh)
        for x in 0..<sw {
            let x0=x*width/sw,x1=min(width,((x+1)*width+sw-1)/sw)
            var sums=(0,0,0),hit=false
            for yy in y0..<y1 {for xx in x0..<x1 {
                let p=yy*width+xx
                sums.0+=Int(rgba[p*4]);sums.1+=Int(rgba[p*4+1]);sums.2+=Int(rgba[p*4+2])
                hit=hit || removal[p] != 0
            }}
            let n=Float((y1-y0)*(x1-x0)),p=y*sw+x
            reduced[p*3]=Float(sums.0)/n;reduced[p*3+1]=Float(sums.1)/n;reduced[p*3+2]=Float(sums.2)/n
            hits[p]=hit
        }
    }
    let ip=image.dataPointer.assumingMemoryBound(to:Float16.self),mp=mask.dataPointer.assumingMemoryBound(to:Float16.self)
    for y in 0..<side {for x in 0..<side {
        let p=y*side+x,r=min(y,sh-1)*sw+min(x,sw-1),hit=y<sh && x<sw && hits[min(y,sh-1)*sw+min(x,sw-1)]
        mp[p]=hit ? 1:0
        for c in 0..<3 {ip[c*side*side+p]=Float16((reduced[r*3+c]/127.5-1)*(hit ? 0:1))}
    }}
    return(sw,sh)
}

func historicalCompose(_ rgba:[UInt8],_ removal:[UInt8],_ width:Int,_ height:Int,
                       _ raw:MLMultiArray,_ content:(Int,Int)) throws -> [UInt8] {
    let (sw,sh)=content,values=raw.dataPointer.assumingMemoryBound(to:Float16.self)
    func value(_ x:Int,_ y:Int,_ c:Int)->Double {Double((Float(values[c*1024*1024+y*1024+x])+1)/2)}
    var result=rgba
    for y in 0..<height {
        let sy=min(Float(sh-1),max(0,(Float(y)+0.5)*Float(sh)/Float(height)-0.5))
        let y0=Int(floor(sy)),y1=min(sh-1,y0+1),dy=Double(sy)-Double(y0)
        for x in 0..<width where removal[y*width+x] != 0 {
            let sx=min(Float(sw-1),max(0,(Float(x)+0.5)*Float(sw)/Float(width)-0.5))
            let x0=Int(floor(sx)),x1=min(sw-1,x0+1),dx=Double(sx)-Double(x0)
            for c in 0..<3 {
                let top=value(x0,y0,c)*(1-dx)+value(x1,y0,c)*dx
                let bottom=value(x0,y1,c)*(1-dx)+value(x1,y1,c)*dx
                let v=top*(1-dy)+bottom*dy
                guard v.isFinite else {throw NativeAdmittedAOTPageRoute.Failure.modelContract}
                result[(y*width+x)*4+c]=UInt8(floor(min(1,max(0,v))*255+0.5))
            }
        }
    }
    return result
}

func bytes(_ array:MLMultiArray)->Data {Data(bytes:array.dataPointer,count:array.count*2)}

// Prior RGB24 cache adapter decoded onto white before extracting RGB8.
func historicalCacheRGB(_ image:CGImage) throws -> [UInt8] {
    let w=image.width,h=image.height
    var rgba=[UInt8](repeating:0,count:w*h*4)
    rgba.withUnsafeMutableBytes {raw in
        let context=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:
                CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:w,height:h))
        context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
    }
    return (0..<w*h).flatMap {Array(rgba[($0*4)..<($0*4+3)])}
}

@main struct AOTTransportReuseSmoke {
    static func main() async throws {
        let image=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        let mask=try MLMultiArray(shape:[1,1,1024,1024],dataType:.float16)
        let expectedImage=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        let expectedMask=try MLMultiArray(shape:[1,1,1024,1024],dataType:.float16)
        let raw=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        var mutable:[UInt8]=[0,255]
        let immutable=try NativeAOTValidatedMask(validating:mutable,width:2,height:1,domain:.strict255)
        mutable[0]=2
        var exported=immutable.bytes;exported[1]=0
        check(immutable.bytes == [0,255] && immutable.foregroundCount == 1 && immutable.hasForeground)
        let logical=try NativeAOTValidatedMask(validating:[1,255],width:2,height:1,domain:.logical01Or255)
        check(logical.foregroundCount == 2)
        for (values,w,h,domain) in [([UInt8(1)],1,1,NativeAOTValidatedMask.Domain.strict255),
            ([2],1,1,.logical01Or255),([],0,1,.strict255),([0],2,1,.strict255),
            ([0],Int.max,2,.strict255),([0],1,Int.max,.strict255)] {
            var rejected=false
            do {_ = try NativeAOTValidatedMask(validating:values,width:w,height:h,domain:domain)}catch {rejected=true}
            check(rejected)
        }
        let empty=try NativeAOTValidatedMask(validating:[0],width:1,height:1,domain:.strict255)
        check(!empty.hasForeground && empty.foregroundCount == 0)
        let p=raw.dataPointer.assumingMemoryBound(to:Float16.self)
        for i in 0..<raw.count {p[i]=Float16(Float(i%997)/498-1)}
        // The final 64-row pass contains one or three rows in these wide cases.
        // Its last masked pixel still supplies the original color to both padding axes.
        for (w,h) in [(1,1),(7,13),(33,17),(1030,3),(607,193),(607,195),(1025,1027)] {
            var rgba=[UInt8](repeating:0,count:w*h*4),rgb=[UInt8](repeating:0,count:w*h*3)
            for i in 0..<w*h {
                rgba[i*4+3]=UInt8((i*13)%256)
                for c in 0..<3 {rgba[i*4+c]=UInt8((i*37+c*67)%256);rgb[i*3+c]=rgba[i*4+c]}
            }
            for on:UInt8 in [1,255] {
                let removal=(0..<w*h).map { ($0%19==0 || $0==w*h-1) ? on:UInt8(0) }
                let expected=try historicalPrepare(rgba,removal,w,h,expectedImage,expectedMask)
                let content=try NativeResidentAOT.prepareRGBA(rgba:rgba,finalMask:removal,width:w,height:h,image:image,mask:mask)
                check(content==expected && bytes(image)==bytes(expectedImage) && bytes(mask)==bytes(expectedMask))
                _ = try NativeResidentAOT.prepare(rgb:rgb,finalMask:removal,width:w,height:h,image:image,mask:mask)
                check(bytes(image)==bytes(expectedImage) && bytes(mask)==bytes(expectedMask))
                let snapshot=try NativeAOTValidatedMask(validating:removal,width:w,height:h,domain:.logical01Or255)
                _ = try NativeResidentAOT.prepare(rgb:rgb,validatedMask:snapshot,image:image,mask:mask)
                check(bytes(image)==bytes(expectedImage) && bytes(mask)==bytes(expectedMask))
                let expectedPixels=try historicalCompose(rgba,removal,w,h,raw,content)
                let actual=try NativeResidentAOT.composeRGBA(source:rgba,finalMask:removal,width:w,height:h,raw:raw,content:content)
                check(actual==expectedPixels)
                let typed=try NativeResidentAOT.composeRGBA(source:rgba,validatedMask:snapshot,raw:raw,content:content)
                check(typed==expectedPixels)
                for i in 0..<w*h {
                    check(actual[i*4+3]==rgba[i*4+3])
                    if removal[i]==0 {for c in 0..<4 {check(actual[i*4+c]==rgba[i*4+c])}}
                }
            }
        }
        // Canonical registration keeps the exact RGB24 output descriptor and
        // refuses transparent or outside-mask-corrupt handoffs. No backend/model.
        let sourceBytes:[UInt8]=[20,30,40,255,50,60,70,255]
        let source=try raster(sourceBytes,width:2,height:1)
        let alphaSource=try NativeAOTAlphaComposition.prepare(source:source)
        let firstPixel = try NativeAOTValidatedMask(validating: [255, 0], width: 2, height: 1, domain: .strict255)
        // Keep only the CGImage alive after the scatter's temporary owners have gone away.
        var writtenAddress: UInt?
        let retained = try autoreleasepool {
            try NativeAOTAlphaComposition.opaqueImage(source: alphaSource, validatedMask: firstPixel) { pixels in
                writtenAddress = UInt(bitPattern: pixels.baseAddress!)
                pixels[0] = 19
            }
        }
        let retainedBytes = retained.dataProvider!.data!
        check(UInt(bitPattern: CFDataGetBytePtr(retainedBytes)) == writtenAddress)
        check(CFDataGetLength(retainedBytes) == 6 && CFDataGetBytePtr(retainedBytes)![0] == 19)
        var outsideRejected = false
        do {
            _ = try NativeAOTAlphaComposition.opaqueImage(source: alphaSource, validatedMask: firstPixel) { $0[3] = 0 }
        } catch NativeAOTAlphaComposition.Failure.opaqueOutsideMismatch { outsideRejected = true }
        check(outsideRejected)
        let wrongShape=try NativeAOTValidatedMask(validating:[255,0],width:1,height:2,domain:.strict255)
        var shapeRejected=false
        do {_ = try NativeAOTAlphaComposition.makeImage(source:alphaSource,restoredRGB:alphaSource.inferenceRGB,validatedMask:wrongShape)}
        catch NativeAOTAlphaComposition.Failure.invalidMask {shapeRejected=true}
        check(shapeRejected)
        shapeRejected=false
        do {_ = try NativeResidentAOT.composeRestoration(source:alphaSource,validatedMask:wrongShape,raw:raw,content:(2,1),calibrateBoundaryBias:false)}
        catch let error as NSError {shapeRejected=error.domain == "NativeAOTCompositionContract" && error.code == 7}
        check(shapeRejected)
        for domain in ["NativeAOTTransportContract","NativeAOTCompositionContract"] {
            var mapped=false
            do {
                if domain == "NativeAOTTransportContract" {
                    _ = try NativeResidentAOT.prepare(rgb:[1,2,3],finalMask:[2],width:1,height:1,image:image,mask:mask)
                } else {
                    _ = try NativeResidentAOT.composePixels(source:[1,2,3],finalMask:[2],width:1,height:1,raw:raw,content:(1,1))
                }
            } catch let error as NSError {mapped=error.domain == domain && error.code == 7}
            check(mapped)
        }
        check(NativeAOTBoundaryBias.prepare(source:[1,2,3],mask:[2],width:1,height:1)==nil)
        let restored=try raster([100,110,120,255,50,60,70,255],width:2,height:1)
        let normalized=try NativeAOTAlphaComposition.legacyRGB24CacheImage(source:source,restored:restored,originalMask:[255,0])!
        check(normalized.bitsPerPixel==24 && normalized.bytesPerRow==6 && normalized.alphaInfo == .none && !normalized.shouldInterpolate)
        let canonical=try NativeAOTAlphaComposition.prepare(source:normalized)
        check(canonical.inferenceRGB==[100,110,120,50,60,70])
        let bad=try raster([100,110,120,255,51,60,70,255],width:2,height:1)
        let rejected=try NativeAOTAlphaComposition.legacyRGB24CacheImage(source:source,restored:bad,originalMask:[255,0])
        check(rejected==nil)
        let transparent=try raster([10,10,10,128,50,60,70,255],width:2,height:1)
        let alphaRejected=try NativeAOTAlphaComposition.legacyRGB24CacheImage(source:transparent,restored:restored,originalMask:[255,0])
        check(alphaRejected==nil)
        for space in [CGColorSpaceCreateDeviceRGB(),CGColorSpace(name:CGColorSpace.sRGB)!,CGColorSpace(name:CGColorSpace.displayP3)!] {
            var rgba=[UInt8](repeating:255,count:7*13*4)
            for i in 0..<7*13 {for c in 0..<3 {rgba[i*4+c]=UInt8((i*37+c*67)%256)}}
            let provider=CGDataProvider(data:Data(rgba) as CFData)!
            let input=CGImage(width:7,height:13,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:7*4,
                space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
                provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
            let expected=try historicalCacheRGB(input)
            let cached=try NativeAOTAlphaComposition.legacyRGB24CacheImage(source:input,restored:input,originalMask:[UInt8](repeating:255,count:7*13))!
            check(cached.bitsPerPixel==24 && cached.bytesPerRow==7*3 && !cached.shouldInterpolate)
            check(Data(cached.dataProvider!.data! as Data)==Data(expected))
        }
        var refused=false
        do {
            _ = try NativeResidentAOT.prepareRGBA(rgba:[0,0,0,255],finalMask:[2],width:1,height:1,image:image,mask:mask)
        } catch {refused=true}
        check(refused)
        p[0] = .nan
        let untouched=try NativeResidentAOT.composeRGBA(source:[1,2,3,4],finalMask:[0],width:1,height:1,raw:raw,content:(1,1))
        check(untouched==[1,2,3,4]) // Unselected model cells cannot authorize writes.
        refused=false
        do {
            _ = try NativeResidentAOT.composeRGBA(source:[1,2,3,4],finalMask:[1],width:1,height:1,raw:raw,content:(1,1))
        } catch {refused=true}
        check(refused)
        let cancelled=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            do {
                _ = try NativeResidentAOT.prepareRGBA(rgba:[0,0,0,255],finalMask:[1],width:1,height:1,image:image,mask:mask)
                return false
            } catch is CancellationError {return true}
            catch {return false}
        }
        let didCancel=await cancelled.value
        check(didCancel)
        print("PASS historical/raw/typed RGBA/RGB transport bit parity14 cases; sealed mask COW/dimensions/binary/logical1/strict1/empty controls; exact original-mask scatter/alpha; RGB24 cache3 colorspaces exact; outside-corruption/nonfinite/invalid-mask rejection; cancellation; modelCalls=0")
    }
}
