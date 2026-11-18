import Foundation
import CoreGraphics

/// Original pixel proof transfers a misread pause's physical ownership only.
/// The destination's text, target, semantic rectangle and typography stay exact.
enum NativeSourceDotRailOwnership {
    typealias Reader = (CGRect, Int, Int) -> [UInt8]?
    struct Result { let regions: [ReaderTranslationRegion] }

    static func applying(_ input: [ReaderTranslationRegion], width: Int, height: Int, reader: Reader) -> Result {
        guard width > 0, height > 0, input.count <= 256,
              Set(input.map(\.id)).count == input.count else { return .init(regions: input) }
        func valid(_ r: CGRect) -> Bool {
            r.width > 0 && r.height > 0 && [r.minX,r.minY,r.maxX,r.maxY].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
        func contains(_ body: ReaderTranslationBalloonInterior, _ r: CGRect) -> Bool {
            guard body.contourVerified == true, valid(body.rect), body.rect.contains(r),
                  body.spans.count >= 4, body.spans.count % 2 == 0 else { return false }
            let rows = body.spans.count / 2
            let first = max(0, Int(floor((r.minY-body.rect.minY)/body.rect.height*CGFloat(rows))))
            let last = min(rows-1, Int(floor((r.maxY-body.rect.minY)/body.rect.height*CGFloat(rows))))
            guard first <= last else { return false }
            return (first...last).allSatisfy { row in
                let l = body.spans[row*2], h = body.spans[row*2+1]
                return l.isFinite && h.isFinite && l >= 0 && h <= 1 && l <= Double(r.minX) && h >= Double(r.maxX)
            }
        }
        var updates = input, consumed = Set<Int>(), attempts = 0
        for index in input.indices {
            let rail = input[index], text = rail.source.filter { !$0.isWhitespace }
            guard (6...24).contains(text.count), text.allSatisfy({ $0 == "0" }),
                  rail.sourceOrientation == .vertical, valid(rail.rect), !rail.isOccludedFinePrint,
                  rail.translation == nil || rail.translation == rail.source,
                  rail.rect.height * CGFloat(height) >= rail.rect.width * CGFloat(width) * 5,
                  let evidence = rail.detectorSeedEvidence, !evidence.isEmpty,
                  evidence.allSatisfy({ $0.isValid && $0.sourceWidth == width && $0.sourceHeight == height && $0.completeCCScan == true &&
                    !$0.components.isEmpty && ($0.candidateComponents?.isEmpty ?? false) &&
                    ($0.ambiguousComponents?.isEmpty ?? false) }) else { continue }
            let owners = input.indices.filter { owner in
                let a = input[owner]
                guard owner != index, !a.isOccludedFinePrint, a.sourceOrientation == .vertical,
                      valid(a.rect), a.source.contains("…"),
                      a.source.unicodeScalars.contains(where: { (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value) }),
                      let body = a.balloonInterior, contains(body, rail.rect), contains(body, a.rect) else { return false }
                if let ownBody = rail.balloonInterior, ownBody.contourVerified == true,
                   (ownBody.rect != body.rect || ownBody.center != body.center || ownBody.spans != body.spans) { return false }
                let gap = max(0, max(a.rect.minX,rail.rect.minX)-min(a.rect.maxX,rail.rect.maxX))
                let overlap = min(a.rect.maxY,rail.rect.maxY)-max(a.rect.minY,rail.rect.minY)
                return gap <= a.rect.width * 1.5 && overlap >= min(a.rect.height,rail.rect.height)*0.75
            }
            guard owners.count == 1, !consumed.contains(owners[0]), attempts < 4 else { continue }
            let owner = owners[0]
            guard let body = input[owner].balloonInterior,
                  !input.indices.contains(where: { other in
                    other != owner && other != index && !input[other].isOccludedFinePrint &&
                    input[other].source.unicodeScalars.contains(where: { (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value) }) &&
                    contains(body,input[other].rect)
                  }) else { continue }
            guard let union = NativeOCRDetectorSeedEvidence.preservingUnion([updates[owner].detectorSeedEvidence,evidence]) else { continue }
            let scope = CGRect(x: rail.rect.minX*CGFloat(width), y: rail.rect.minY*CGFloat(height),
                               width: rail.rect.width*CGFloat(width), height: rail.rect.height*CGFloat(height)).integral
            let w = Int(scope.width), h = Int(scope.height)
            guard w >= 6, h >= 24, w <= 128, h <= 1024, w*h <= 65_536 else { continue }
            attempts += 1
            // CTC's zero count is only a nomination: it may compress several
            // real dots. Independent original round-core geometry supplies the
            // count; no OCR spelling or translated text is reconstructed.
            guard let rgba = reader(scope,w,h), dotCount(rgba,width:w,height:h) != nil else { continue }
            updates[owner].detectorSeedEvidence = union
            let rects = [rail.rect] + rail.auxiliaryInkRects
            updates[owner].auxiliaryInkRects += rects.filter { !updates[owner].auxiliaryInkRects.contains($0) }
            let polygons = rail.auxiliaryInkPolygons + (rail.polygon.count >= 3 ? [rail.polygon] : [])
            updates[owner].auxiliaryInkPolygons += polygons.filter { !updates[owner].auxiliaryInkPolygons.contains($0) }
            consumed.insert(index)
        }
        return .init(regions: updates.enumerated().filter { !consumed.contains($0.offset) }.map(\.element))
    }

    /// Distinct compact, filled round cores with one regular vertical pitch.
    /// Actual zero glyphs have holes and fail filled-core proof. Crop-local paper
    /// color is measured; no authored foreground color authorizes attachment.
    static func dotCount(_ rgba: [UInt8], width: Int, height: Int) -> Int? {
        guard width >= 6, height >= 24, width <= 128, height <= 1024,
              width*height <= 65_536, rgba.count == width*height*4 else { return nil }
        var bins = [Int](repeating:0,count:4096)
        for i in 0..<width*height { bins[Int(rgba[i*4]>>4)*256+Int(rgba[i*4+1]>>4)*16+Int(rgba[i*4+2]>>4)] += 1 }
        guard let mode = bins.indices.max(by:{bins[$0]<bins[$1]}) else { return nil }
        let paper = [(mode>>8)*16+8,((mode>>4)&15)*16+8,(mode&15)*16+8]
        var ink = [Bool](repeating:false,count:width*height)
        for i in ink.indices { ink[i] = (0..<3).map { abs(Int(rgba[i*4+$0])-paper[$0]) }.max()! >= 65 }
        var dots: [(x:Double,y:Double,w:Int,h:Int)] = []
        for start in ink.indices where ink[start] {
            var queue = [start], head = 0, l = width, t = height, r = 0, b = 0
            ink[start] = false
            while head < queue.count {
                let i=queue[head],x=i%width,y=i/width;head+=1;l=min(l,x);r=max(r,x);t=min(t,y);b=max(b,y)
                for yy in max(0,y-1)...min(height-1,y+1) { for xx in max(0,x-1)...min(width-1,x+1) {
                    let j=yy*width+xx;if ink[j] {ink[j]=false;queue.append(j)}
                }}
            }
            if queue.count < 4 { continue }
            let w=r-l+1,h=b-t+1
            guard l > 0,t > 0,r < width-1,b < height-1,min(w,h)>=3,
                  Double(max(w,h)) <= Double(min(w,h))*1.6, Double(max(w,h)) <= Double(width)*0.6,
                  Double(queue.count)/Double(w*h) >= 0.65 else { return nil }
            dots.append((Double(l+r)/2,Double(t+b)/2,w,h))
        }
        guard (6...24).contains(dots.count) else { return nil }
        dots.sort{$0.y<$1.y}
        let widths=dots.map(\.w), heights=dots.map(\.h), pitch=zip(dots,dots.dropFirst()).map{$1.y-$0.y}
        let median=pitch.sorted()[pitch.count/2],size=Double((widths+heights).max()!)
        guard widths.max()!-widths.min()!<=2,heights.max()!-heights.min()!<=2,
              dots.map(\.x).max()!-dots.map(\.x).min()! <= 2,
              median >= size*1.4,median <= size*4,
              pitch.allSatisfy({abs($0-median)<=median*0.15}) else { return nil }
        return dots.count
    }
}
