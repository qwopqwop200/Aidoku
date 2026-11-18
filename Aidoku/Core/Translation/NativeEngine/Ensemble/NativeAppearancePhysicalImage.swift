import AidokuNativeCV
import CoreGraphics
import Foundation

enum NativeAppearancePhysicalImage {
    struct Components {
        let labels:[Int32]
        let bounds:[CGRect] // includes background0
        let areas:[Int]
    }
    static func components(_ mask:[UInt8],width w:Int,height h:Int) throws -> Components {
        let n=try NativeOpenCV.count(width:w,height:h)
        guard mask.count==n else {throw NativeOpenCV.Failure.invalidBuffer}
        let capacity=n/2+2
        var labels=[Int32](repeating:0,count:n),stats=[Int32](repeating:0,count:capacity*5)
        var centroids=[Double](repeating:0,count:capacity*2),count:Int32=0
        try mask.withUnsafeBufferPointer {src in try labels.withUnsafeMutableBufferPointer {dst in
            try stats.withUnsafeMutableBufferPointer {st in try centroids.withUnsafeMutableBufferPointer {ct in
                try NativeOpenCV.check(acv_components(src.baseAddress,Int32(w),Int32(h),8,dst.baseAddress,
                    st.baseAddress,ct.baseAddress,capacity,&count))
            }}
        }}
        return .init(labels:labels,bounds:(0..<Int(count)).map {i in
            CGRect(x:Int(stats[i*5]),y:Int(stats[i*5+1]),width:Int(stats[i*5+2]),height:Int(stats[i*5+3]))
        },areas:(0..<Int(count)).map {Int(stats[$0*5+4])})
    }
    static func gaussian(_ values:[Float],width w:Int,height h:Int,sigma:Double) throws -> [Float] {
        guard sigma.isFinite,sigma>0,values.count==w*h else {throw NativeOpenCV.Failure.invalidBuffer}
        // OpenCV's automatic CV_32F Gaussian kernel uses round(8*sigma+1)|1.
        let size=max(1,Int((sigma*8+1).rounded(.toNearestOrEven))|1)
        return try NativeOpenCV.transform(values,outputCount:values.count,zero:Float(0)) {
            acv_blur($0,$1,Int32(w),Int32(h),1,1,Int32(size),sigma,0,4)
        }
    }
    static func erode(_ mask:[UInt8],width w:Int,height h:Int,size:Int=3) throws -> [UInt8] {
        guard mask.count==w*h,size>0 else {throw NativeOpenCV.Failure.invalidBuffer}
        return try NativeOpenCV.transform(mask,outputCount:mask.count,zero:UInt8(0)) {
            acv_morphology($0,$1,Int32(w),Int32(h),0,0,0,Int32(size),Int32(size),0)
        }
    }
    static func gradient(_ values:[Float],width w:Int,height h:Int)->(x:[Float],y:[Float]) {
        var gx=[Float](repeating:0,count:values.count),gy=gx
        for y in 0..<h {for x in 0..<w {
            let left=max(0,x-1),right=min(w-1,x+1),top=max(0,y-1),bottom=min(h-1,y+1)
            gx[y*w+x]=(values[y*w+right]-values[y*w+left])/Float(max(1,right-left))
            gy[y*w+x]=(values[bottom*w+x]-values[top*w+x])/Float(max(1,bottom-top))
        }}
        return (gx,gy)
    }
    static func sample(rgb:[UInt8],width w:Int,height h:Int,x:[Float],y:[Float],rows:Int,columns:Int) throws -> (rgb:[UInt8],valid:[Bool]) {
        guard rgb.count==w*h*3,x.count==y.count,x.count==rows*columns,rows>0,columns>0 else {
            throw NativeOpenCV.Failure.invalidBuffer
        }
        let valid=x.indices.map {x[$0].isFinite && y[$0].isFinite && x[$0]>=0 && y[$0]>=0 && x[$0]<=Float(w-1) && y[$0]<=Float(h-1)}
        let xx=x.map {$0.isFinite ? $0:0},yy=y.map {$0.isFinite ? $0:0}
        var output=[UInt8](repeating:0,count:x.count*3)
        try rgb.withUnsafeBufferPointer {source in try output.withUnsafeMutableBufferPointer {target in
            try xx.withUnsafeBufferPointer {mx in try yy.withUnsafeBufferPointer {my in
                try NativeOpenCV.check(acv_remap(source.baseAddress,target.baseAddress,Int32(w),Int32(h),
                    Int32(columns),Int32(rows),3,0,mx.baseAddress,my.baseAddress,1,1,0))
            }}
        }}
        return (output,valid)
    }
    static func distance(_ a:[Float],_ b:[Float])->Float {
        let x=a[0]-b[0],y=a[1]-b[1],z=a[2]-b[2]
        return sqrt((x*x+y*y)+z*z)
    }
    static func sourceCore(_ input:SourceNativeInput,prediction:[String:Any],ops:any NativeAppearanceImageOperations) throws -> [UInt8]? {
        guard let fill=(prediction["fill"] as? [String:Any])?["rgb"] as? [Double],
              let outline=prediction["outline"] as? [String:Any],let outlineRGB=outline["rgb"] as? [Double],
              let background=(prediction["background"] as? [String:Any])?["rgb"] as? [Double] else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("source core paint")
        }
        let w=input.width,h=input.height,n=w*h
        let image=try ops.lab(rgb:input.rgb,width:w,height:h),colors=try ops.lab(colors:[fill,outlineRGB,background])
        let fillLab=colors[0],contrast=Double(distance(fillLab,colors[2])),tolerance=min(18,max(3,contrast*0.35))
        let chroma=sqrt(fillLab[1]*fillLab[1]+fillLab[2]*fillLab[2])
        let roi=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        var core=[UInt8](repeating:0,count:n)
        for p in 0..<n where input.ownMask[p] != 0 {
            let color=Array(image[p*3..<p*3+3]);var similar=Double(distance(color,fillLab))<=tolerance
            if chroma>=20 {
                let pixelChroma=sqrt(color[1]*color[1]+color[2]*color[2])
                let cosine=(color[1]*fillLab[1]+color[2]*fillLab[2])/max(1e-6,pixelChroma*chroma)
                similar = similar || (cosine>=0.96 && pixelChroma>=max(15,chroma*0.4) && abs(color[0]-fillLab[0])<25)
            }
            if similar {core[p]=1}
        }
        if outline["present"] as? Bool == true {
            let ring=(0..<n).map {p in distance(Array(image[p*3..<p*3+3]),colors[1])<=8 ? UInt8(1):0}
            let closed=try ops.close(ring,width:w,height:h,size:3),filled=try ops.fillHoles(closed,width:w,height:h)
            let enclosed=(0..<n).map {core[$0] != 0 && filled[$0] != 0 && closed[$0]==0 ? UInt8(1):0}
            let enclosedSeeds=(0..<n).filter {enclosed[$0] != 0 && roi[$0] != 0}.count
            let coreSeeds=(0..<n).filter {core[$0] != 0 && roi[$0] != 0}.count
            if Double(enclosedSeeds)>=max(12,Double(coreSeeds)*0.25) {core=enclosed}
        } else if contrast<8 {return nil}
        let components=try self.components(core,width:w,height:h)
        var seeds=[Int](repeating:0,count:components.areas.count)
        for p in 0..<n where roi[p] != 0 {seeds[Int(components.labels[p])]+=1}
        core=components.labels.map {$0>0 && seeds[Int($0)]>=3 ? 1:0}
        return core.filter({$0 != 0}).count>=20 ? core:nil
    }
}
