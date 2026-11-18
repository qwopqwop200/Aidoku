import CoreGraphics
import Foundation

/// Source-pixel witness consumed by the OCR cohort separation veto.
enum NativeOutlinedLobeProof {
    struct Evidence {}
    static func inspect(image: CGImage, first: CGRect, second: CGRect, glyph: CGFloat) -> Evidence? {
        guard glyph.isFinite, glyph >= 4, glyph <= 128,
              [first, second].allSatisfy({ $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else { return nil }
        let a = first.midX < second.midX ? first : second
        let b = first.midX < second.midX ? second : first
        guard a.maxX < b.minX, min(a.maxY,b.maxY) > max(a.minY,b.minY) else { return nil }
        let bounds=CGRect(x:0,y:0,width:image.width,height:image.height)
        let roi=a.union(b).insetBy(dx:-glyph,dy:-glyph*1.5).integral.intersection(bounds)
        guard roi.width <= 512, roi.height <= 512, let crop=image.cropping(to:roi) else { return nil }
        let w=crop.width,h=crop.height
        var rgba=[UInt8](repeating:0,count:w*h*4)
        let drawn=rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return false}
            ctx.draw(crop,in:CGRect(x:0,y:0,width:w,height:h));return true
        }
        guard drawn else{return nil}
        var seen=[UInt8](repeating:0,count:w*h)
        func white(_ i:Int)->Bool {min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])>=235}
        for seed in 0..<w*h where seen[seed]==0 && white(seed) {
            var queue=[seed];seen[seed]=1;var cursor=0
            while cursor<queue.count {
                let i=queue[cursor];cursor+=1;let x=i%w,y=i/w
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx>=0 && nx<w && ny>=0 && ny<h {
                    let j=ny*w+nx
                    if seen[j]==0 && white(j){seen[j]=1;queue.append(j)}
                }
            }
            guard queue.count >= Int(glyph*8), queue.count < w*h/5 else{continue}
            var top=[Int](repeating:h,count:w),bottom=[Int](repeating:-1,count:w)
            for i in queue{top[i%w]=min(top[i%w],i/w);bottom[i%w]=max(bottom[i%w],i/w)}
            func shoulder(_ r:CGRect)->(x:Int,top:Int,bottom:Int)? {
                let lo=max(0,Int(r.minX-roi.minX)),hi=min(w-1,Int(r.maxX-roi.minX))
                guard lo<=hi else{return nil}
                let valid=(lo...hi).filter { x in CGFloat(top[x])+roi.minY < r.minY && CGFloat(bottom[x])+roi.minY > r.maxY }
                guard valid.count >= Int(glyph*0.35),let x=valid.max(by:{bottom[$0]-top[$0]<bottom[$1]-top[$1]}) else{return nil}
                return(x,top[x],bottom[x])
            }
            guard let l=shoulder(a),let r=shoulder(b),l.x<r.x else{continue}
            let low=max(l.x+1,Int(a.maxX-roi.minX-glyph*0.35))
            let high=min(r.x-1,Int(b.minX-roi.minX+glyph*0.35))
            guard low<=high else{continue}
            let valid=(low...high).filter{bottom[$0]>top[$0]}
            guard valid.count >= Int(glyph*0.35),let tx=valid.max(by:{top[$0]<top[$1]}),
                  let bx=valid.min(by:{bottom[$0]<bottom[$1]}) else{continue}
            let depth=CGFloat(min(top[tx]-l.top,top[tx]-r.top,l.bottom-bottom[bx],r.bottom-bottom[bx]))
            let neck=CGFloat(bottom[bx]-top[tx]),lh=CGFloat(l.bottom-l.top),rh=CGFloat(r.bottom-r.top)
            guard depth >= glyph*0.65,abs(tx-bx)<=Int(glyph),neck>glyph,
                  neck <= min(lh,rh)*0.8 else{continue}
            // A connected white stroke with two notches is not necessarily
            // a closed compartment: reject open artwork with the same extrema.
            var outside = [UInt8](repeating: 0, count: w*h)
            for i in queue { outside[i] = 2 }
            // Only the original image boundary can complete a truncated rim.
            // An artificial crop edge must remain open to the exterior flood.
            if roi.maxY == CGFloat(image.height) {
                let ends = queue.filter { $0/w == h-1 }.map { $0%w }.sorted()
                let groups = ends.reduce(into: [[Int]]()) { groups, x in
                    if let last=groups.last?.last, x==last+1 { groups[groups.count-1].append(x) }
                    else { groups.append([x]) }
                }
                if groups.count == 2, let first=ends.first, let last=ends.last,
                   last-first >= 3,
                   !queue.contains(where: { $0/w==0 || $0%w==0 || $0%w==w-1 }) {
                    for x in first...last { outside[(h-1)*w+x] = 2 }
                }
            }
            var flood: [Int] = []
            func enqueueOutside(_ x:Int,_ y:Int) {
                let i=y*w+x
                if outside[i] == 0 { outside[i]=1; flood.append(i) }
            }
            for x in 0..<w { enqueueOutside(x,0); enqueueOutside(x,h-1) }
            for y in 0..<h { enqueueOutside(0,y); enqueueOutside(w-1,y) }
            var head=0
            while head<flood.count {
                let i=flood[head];head+=1;let x=i%w,y=i/w
                if x>0 { enqueueOutside(x-1,y) };if x+1<w { enqueueOutside(x+1,y) }
                if y>0 { enqueueOutside(x,y-1) };if y+1<h { enqueueOutside(x,y+1) }
            }
            func owned(_ r:CGRect)->Bool {
                let x=Int(r.midX-roi.minX),y=Int(r.midY-roi.minY)
                return x>=0 && x<w && y>=0 && y<h && outside[y*w+x]==0
            }
            guard owned(a),owned(b) else { continue }
            return Evidence()
        }
        return nil
    }
}
