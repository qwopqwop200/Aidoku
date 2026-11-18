import CoreGraphics
import Foundation

/// pixel_role_estimation.features at explicit original crop positions.
enum NativeAppearancePixelFeatures71 {
    static func extract(_ input:SourceNativeInput,positions:[Int],fill:[Double],outline:[Double],background:[Double],
                        outlinePresent:Bool,outlineProbability:Double,ops:any NativeAppearanceImageOperations) throws -> [[Float]] {
        try input.validate()
        let w=input.width,h=input.height,n=w*h,f=Float(max(1,input.fontPriorSourcePixels))
        guard positions.allSatisfy({$0>=0 && $0<n}),outlineProbability.isFinite else {throw SourceNativeInput.Failure.invalidPredictions}
        let lab=try ops.lab(rgb:input.rgb,width:w,height:h)
        let colors=try ops.lab(colors:[fill,outline,background])
        let means=try [3,9].map {try ops.rgbBoxMean(rgb:input.rgb,width:w,height:h,size:$0)}
        let gradient=try ops.rgbSobelMagnitude(rgb:input.rgb,width:w,height:h)
        let owned=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        let merged=try ops.raster(polygons:[input.mergedPolygon],width:w,height:h)
        let areas=[owned,merged,input.ownMask.map {$0==0 ? UInt8(0):1}]
        let signed=try areas.map { area -> [Float] in
            let inside=try ops.distance(area,width:w,height:h,maskSize:3)
            let outside=try ops.distance(area.map {$0==0 ? 1:0},width:w,height:h,maskSize:3)
            return zip(inside,outside).map {min(2,max(-2,($0-$1)/f))}
        }
        let rect=try ops.minimumAreaRectangle(input.mergedPolygon)
        guard rect.count==5,lab.count==n*3,means.allSatisfy({$0.count==n*3}),gradient.count==n else {
            throw NativeAppearanceSourceFeatures209.Failure.invalidImageOperation
        }
        let angle=rect[4]*Double.pi/180,co=Float(cos(angle)),si=Float(sin(angle))
        return positions.map {p in
            let raw=(0..<3).map {Float(input.rgb[p*3+$0])/255}
            var row=raw+[lab[p*3]/100,lab[p*3+1]/128,lab[p*3+2]/128]
            for mean in means {row += (0..<3).map {raw[$0]-mean[p*3+$0]}}
            row.append(gradient[p]);row += input.rf[p*27..<p*27+27]
            let primary=input.primary[p],boundary=input.boundary[p]
            row += [primary,boundary,abs(primary-boundary)]
            row += input.ocr[p*8..<p*8+8]
            for i in 0..<3 {row += [areas[i][p]==0 ? 0:1,signed[i][p]]}
            let x=Float(p%w)-Float(rect[0]),y=Float(p/w)-Float(rect[1])
            let u=(x*co+y*si)/Float(max(1,rect[2]*0.5)),v=(-x*si+y*co)/Float(max(1,rect[3]*0.5))
            row += [min(2,max(-2,u)),min(2,max(-2,v))]
            for color in colors {
                let dl=lab[p*3]-color[0],da=lab[p*3+1]-color[1],db=lab[p*3+2]-color[2]
                let distance=sqrt((dl*dl+da*da)+db*db)
                row += [distance/100,exp(-0.5*(distance/10)*(distance/10))]
            }
            row += [input.rf[p*27]*primary,input.rf[p*27+3]*primary,
                    input.rf[p*27+6]*(1-primary),input.rf[p*27+9]*(1-primary),outlinePresent ? 1:0,Float(outlineProbability)]
            return row
        }
    }
}
