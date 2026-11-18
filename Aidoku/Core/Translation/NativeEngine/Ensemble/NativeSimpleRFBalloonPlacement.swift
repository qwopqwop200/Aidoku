import CoreGraphics
import CryptoKit
import Foundation

/// Immutable, explicit renderer-only domain carrier. No Codable conformance,
/// registry, saved-evidence dictionary or native/RGB/erasure certificate.
struct NativeSimpleRFBalloonPlacement: @unchecked Sendable {
    enum Failure: Error { case sourceBinding, viewportBinding, ownerBinding, duplicateOwner, unavailableDomain }
    struct Capacity: Sendable {
        let rectNormalized: [Double]
        let intervalRowsNormalized: [[Double]]
        let sourcePixelArea: Int
        let sourcePixelRunsSHA256: String
        func primarySpans(owner: [Double]) -> [Double] {
            let left = owner[0], right = owner[0]+owner[2]
            return intervalRowsNormalized.flatMap { row -> [Double] in
                let pairs = stride(from: 0, to: row.count, by: 2).map { (row[$0], row[$0+1]) }
                guard let best = pairs.max(by: { a,b in
                    let x=max(0,min(a.1,right)-max(a.0,left)), y=max(0,min(b.1,right)-max(b.0,left))
                    return x == y ? a.1-a.0 < b.1-b.0 : x < y
                }) else { return [rectNormalized[0],rectNormalized[0]] }
                return [best.0,best.1]
            }
        }
    }
    struct Constraint: Sendable {
        let sourceIdentity: String
        let policyIdentity: String
        let sourceOwnerBoundsNormalized: [Double]
        let viewport: CGSize
        let capacity: Capacity
        let assignment: NativeSimpleRFBalloonCoreDomain.Assignment
        var ownerMaskCoverage: Double {
            Double(assignment.positiveOwnerPixelCentres)/Double(max(1,assignment.ownerPixelCentres))
        }
        /// Retained effect bounds in actual OUTPUT pixels. Avoid a lossy
        /// caller-side rect/scale: outward interval arithmetic preserves every
        /// possibly touched source pixel. Nonunit exact-boundary placements
        /// can conservatively include an adjacent pixel; unit/source viewport
        /// keeps the original exact mask decision with no extra padding.
        func contains(outputRect rect:CGRect,outputScale scale:CGFloat,viewport actual:CGSize)->Bool {
            contains(outputRect:rect,outputScale:CGSize(width:scale,height:scale),viewport:actual)
        }
        func contains(outputRect rect:CGRect,outputScale scale:CGSize,viewport actual:CGSize)->Bool {
            guard actual==viewport,scale.width.isFinite,scale.height.isFinite,scale.width>0,scale.height>0,
                  !rect.isEmpty,!rect.isNull,!rect.isInfinite,
                  [rect.minX,rect.minY,rect.maxX,rect.maxY].allSatisfy(\.isFinite),
                  rect.minX>=0,rect.minY>=0 else{return false}
            if scale.width==1,scale.height==1{return contains(viewportRect:rect,viewport:actual)}
            let pageWidth=viewport.width*scale.width,pageHeight=viewport.height*scale.height
            let width=CGFloat(assignment.query.mask.sourceWidth),height=CGFloat(assignment.query.mask.sourceHeight)
            let sx=width/viewport.width,sy=height/viewport.height
            guard pageWidth.isFinite,pageHeight.isFinite,rect.maxX<=pageWidth,rect.maxY<=pageHeight,
                  sx.isFinite,sy.isFinite,sx>0,sy>0 else{return false}
            func lower(_ value:CGFloat,_ factor:CGFloat,_ outputScale:CGFloat,_ identity:Bool)->CGFloat {
                if identity{return floor(value)}
                return value==0 ? 0:floor(((value/outputScale).nextDown*factor.nextDown).nextDown)
            }
            func upper(_ value:CGFloat,_ factor:CGFloat,_ outputScale:CGFloat,_ identity:Bool)->CGFloat {
                identity ? ceil(value):ceil(((value/outputScale).nextUp*factor.nextUp).nextUp)
            }
            let identityX=width==viewport.width && scale.width==1,identityY=height==viewport.height && scale.height==1
            let left=lower(rect.minX,sx,scale.width,identityX),top=lower(rect.minY,sy,scale.height,identityY)
            let right=upper(rect.maxX,sx,scale.width,identityX),bottom=upper(rect.maxY,sy,scale.height,identityY)
            return assignment.contains(sourceRect:CGRect(x:left,y:top,width:right-left,height:bottom-top),sourceIdentity:sourceIdentity)
        }
        func contains(viewportRect: CGRect, viewport actual: CGSize) -> Bool {
            guard actual == viewport,!viewportRect.isEmpty,!viewportRect.isNull,!viewportRect.isInfinite,
                  [viewportRect.minX,viewportRect.minY,viewportRect.maxX,viewportRect.maxY].allSatisfy(\.isFinite),
                  viewportRect.minX>=0,viewportRect.minY>=0,viewportRect.maxX<=viewport.width,viewportRect.maxY<=viewport.height else{return false}
            let width=CGFloat(assignment.query.mask.sourceWidth),height=CGFloat(assignment.query.mask.sourceHeight)
            // Identity coordinates MUST stay bit-exact: x*W/W can round a
            // one-ULP-outside halo edge back onto a mask boundary. At other
            // viewport scales round the touched source-pixel ROI OUTWARDS.
            if width==viewport.width,height==viewport.height {
                return assignment.contains(sourceRect:viewportRect,sourceIdentity:sourceIdentity)
            }
            let sx=width/viewport.width,sy=height/viewport.height
            let left=viewportRect.minX==0 ? 0:floor((viewportRect.minX*sx).nextDown)
            let top=viewportRect.minY==0 ? 0:floor((viewportRect.minY*sy).nextDown)
            let right=viewportRect.maxX==viewport.width ? width:ceil((viewportRect.maxX*sx).nextUp)
            let bottom=viewportRect.maxY==viewport.height ? height:ceil((viewportRect.maxY*sy).nextUp)
            let source=CGRect(x:left,y:top,width:right-left,height:bottom-top)
            return assignment.contains(sourceRect:source,sourceIdentity:sourceIdentity)
        }
    }
    private struct Owner: Sendable {
        let bounds: [Double]
        let constraint: Constraint?
    }
    private struct Raster: Sendable {
        let x: Int, y: Int, width: Int, height: Int
        let rows: [[Int]] // Absolute source-pixel half-open run edges.
    }
    let sourceIdentity: String
    let policyIdentity: String
    let ownerCohortSHA256: String
    let viewport: CGSize
    private let original: CGImage
    private let rawRF: NativeRFDETRLayoutResult
    private let configuration: NativeSimpleRFBalloonCoreDomain.Configuration
    private let owners: [String:Owner]
    private let capacities: [String:Capacity]

    static func prepareIfRequested(original: CGImage, rawRF: NativeRFDETRLayoutResult,
                                   items: [[String:Any]], viewport: CGSize) throws -> Self? {
        guard let configuration = try NativeSimpleRFBalloonCoreDomain.Configuration.configured() else { return nil }
        return try Self(original:original,rawRF:rawRF,items:items,viewport:viewport,configuration:configuration)
    }

    init(original: CGImage, rawRF: NativeRFDETRLayoutResult, items: [[String:Any]], viewport: CGSize,
         configuration: NativeSimpleRFBalloonCoreDomain.Configuration) throws {
        let decoded=try NativeRFDETRSourceImage.decode(original)
        guard rawRF.imageIdentity == decoded.identity,rawRF.sourceWidth == original.width,
              rawRF.sourceHeight == original.height else { throw Failure.sourceBinding }
        try self.init(original:original,rawRF:rawRF,items:items,viewport:viewport,configuration:configuration,
            validatedIdentity:decoded.identity,reusedCapacities:[:])
    }

    /// Explicit rebinding to the actual current display-owner roster. Changes
    /// no owner, source rectangle or paragraph; reuses immutable raw masks.
    func rebinding(items: [[String:Any]], viewport: CGSize) throws -> Self {
        try Self(original:original,rawRF:rawRF,items:items,viewport:viewport,configuration:configuration,
            validatedIdentity:sourceIdentity,reusedCapacities:capacities)
    }

    private init(original:CGImage,rawRF:NativeRFDETRLayoutResult,items:[[String:Any]],viewport:CGSize,
                 configuration:NativeSimpleRFBalloonCoreDomain.Configuration,validatedIdentity:String,
                 reusedCapacities:[String:Capacity]) throws {
        guard viewport.width.isFinite,viewport.height.isFinite,viewport.width>0,viewport.height>0,
              items.count<=4096 else { throw Failure.viewportBinding }
        var ids:[String]=[],bounds:[[Double]]=[],seen=Set<String>()
        for item in items {
            guard let id=item["id"]as?String,!id.isEmpty,let r=Self.sourceBounds(item) else { continue }
            guard seen.insert(id).inserted else { throw Failure.duplicateOwner }
            ids.append(id);bounds.append(r)
        }
        let size=CGSize(width:original.width,height:original.height)
        let sourceOwners=bounds.map {CGRect(x:$0[0]*size.width,y:$0[1]*size.height,width:$0[2]*size.width,height:$0[3]*size.height)}
        let assignments=try NativeSimpleRFBalloonCoreDomain.assign(sourceOwnerBounds:sourceOwners,result:rawRF,
            sourceIdentity:validatedIdentity,configuration:configuration)
        var capacities=reusedCapacities,records:[String:Owner]=[:],cohort=Data()
        for i in ids.indices {
            cohort.append(contentsOf:ids[i].utf8);cohort.append(0)
            for value in bounds[i] { var bits=value.bitPattern.bigEndian;withUnsafeBytes(of:&bits){cohort.append(contentsOf:$0)} }
            let constraint:Constraint?
            if let assignment=assignments[i] {
                let key="\(assignment.queryID):\(assignment.territoryID)"
                if capacities[key]==nil {
                    guard let raster=Self.raster(assignment) else { throw Failure.unavailableDomain }
                    capacities[key]=Self.capacity(raster,width:original.width,height:original.height)
                }
                constraint=Constraint(sourceIdentity:validatedIdentity,policyIdentity:configuration.cacheIdentity,
                    sourceOwnerBoundsNormalized:bounds[i],viewport:viewport,capacity:capacities[key]!,assignment:assignment)
            } else {constraint=nil}
            records[ids[i]]=Owner(bounds:bounds[i],constraint:constraint)
        }
        self.original=original;self.rawRF=rawRF;self.configuration=configuration
        self.sourceIdentity=validatedIdentity;self.policyIdentity=configuration.cacheIdentity
        self.ownerCohortSHA256=SHA256.hash(data:cohort).map{String(format:"%02x",$0)}.joined()
        self.viewport=viewport;self.owners=records;self.capacities=capacities
    }

    func validate(original actual:CGImage,viewport actualViewport:CGSize) throws {
        guard actual === original,actual.width == rawRF.sourceWidth,actual.height == rawRF.sourceHeight else { throw Failure.sourceBinding }
        guard actualViewport == viewport else { throw Failure.viewportBinding }
    }
    func constraint(for raw:[String:Any],viewport actual:CGSize) throws -> Constraint? {
        guard actual == viewport else { throw Failure.viewportBinding }
        // Retained source lettering is not newly placed translated paint.
        // Its source/erasure authority remains entirely outside this option.
        guard raw["keptLettering"]as?Bool != true,raw["sourceTextOnly"]as?Bool != true else{return nil}
        guard let id=raw["id"]as?String,let owner=owners[id] else { return nil }
        guard let bounds=Self.sourceBounds(raw),bounds.map(\.bitPattern)==owner.bounds.map(\.bitPattern) else { throw Failure.ownerBinding }
        return owner.constraint
    }
    /// nil=unassigned/unobserved owner, false=paint leaves SAME assigned domain.
    /// Binding errors throw; a stale item cannot silently become a certificate.
    func contains(raw:[String:Any],retainedGlyphAndHalo rect:CGRect,viewport:CGSize) throws -> Bool? {
        try constraint(for:raw,viewport:viewport).map{$0.contains(viewportRect:rect,viewport:viewport)}
    }
    var audit:[String:Any] {
        ["status":"explicit-source-bound-raw-rf-core-placement-only","sourceIdentity":sourceIdentity,
         "policyIdentity":policyIdentity,"ownerCohortSHA256":ownerCohortSHA256,"owners":owners.count,
         "assignedOwners":owners.values.filter{$0.constraint != nil}.count,"uniqueDomains":capacities.count,
         "modelEstimated":true,"nativeVerified":false,"sourceErasureAuthority":false,"modelCalls":0,
         "geometry":"Exact source pixel/territory final predicate; conservative intersected scanline bands for proposals only"]
    }
    private static func sourceBounds(_ raw:[String:Any])->[Double]? {
        guard let r=raw["sourceBounds"]as?[Double],r.count==4,r.allSatisfy(\.isFinite),r[2]>0,r[3]>0,
              CGRect(x:0,y:0,width:1,height:1).insetBy(dx:-1e-9,dy:-1e-9).contains(CGRect(x:r[0],y:r[1],width:r[2],height:r[3])) else{return nil}
        return r
    }
    private static func raster(_ assignment:NativeSimpleRFBalloonCoreDomain.Assignment)->Raster? {
        let query=assignment.query,side=NativeRFDETRLayoutResource.maskSide,width=query.mask.sourceWidth,height=query.mask.sourceHeight
        let cells=query.labels.indices.filter{query.labels[$0]==assignment.territoryID}
        guard let first=cells.first else{return nil}
        var minX=first%side,maxX=minX,minY=first/side,maxY=minY
        for cell in cells {minX=min(minX,cell%side);maxX=max(maxX,cell%side);minY=min(minY,cell/side);maxY=max(maxY,cell/side)}
        // Topology-derived computational ROI only. A bilinear neighbour can
        // affect at most one native cell away; extra2source pixels cover F32
        // rounding. Never clip to RF model boxes, source owners or GT geometry.
        let left=max(0,Int(floor((Double(minX)-0.5)*Double(width)/Double(side)-0.5))-2)
        let right=min(width,Int(ceil((Double(maxX)+1.5)*Double(width)/Double(side)-0.5))+3)
        let top=max(0,Int(floor((Double(minY)-0.5)*Double(height)/Double(side)-0.5))-2)
        let bottom=min(height,Int(ceil((Double(maxY)+1.5)*Double(height)/Double(side)-0.5))+3)
        guard left<right,top<bottom else{return nil}
        var rows:[[Int]]=[],x0=width,x1=0,y0=height,y1=0
        for y in top..<bottom {
            var runs:[Int]=[],start:Int?
            for x in left...right {
                let inside=x<right && query.territory(sourceX:x,sourceY:y)==assignment.territoryID
                if inside && start==nil {start=x}
                if !inside,let a=start {runs += [a,x];start=nil;x0=min(x0,a);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y+1)}
            }
            rows.append(runs)
        }
        guard x0<x1,y0<y1 else{return nil}
        return Raster(x:x0,y:y0,width:x1-x0,height:y1-y0,rows:Array(rows[(y0-top)..<(y1-top)]))
    }
    private static func intersect(_ a:[Int],_ b:[Int])->[Int] {
        var result:[Int]=[],i=0,j=0
        while i<a.count && j<b.count {
            let left=max(a[i],b[j]),right=min(a[i+1],b[j+1])
            if left<right {result += [left,right]}
            if a[i+1]<b[j+1] {i+=2}else{j+=2}
        }
        return result
    }
    private static func capacity(_ raster:Raster,width:Int,height:Int)->Capacity {
        let count=max(2,min(512,raster.height))
        var rows:[[Double]]=[]
        for band in 0..<count {
            let low=Double(band)*Double(raster.height)/Double(count),high=Double(band+1)*Double(raster.height)/Double(count)
            let first=max(0,Int(floor(low))),last=min(raster.height-1,Int(ceil(high))-1)
            var safe=raster.rows[first]
            if first<last {for y in (first+1)...last {safe=intersect(safe,raster.rows[y]);if safe.isEmpty{break}}}
            if safe.count>128 {
                let selected=stride(from:0,to:safe.count,by:2).sorted{safe[$0+1]-safe[$0]>safe[$1+1]-safe[$1]}.prefix(64).sorted()
                safe=selected.flatMap{[safe[$0],safe[$0+1]]}
            }
            rows.append(safe.map{Double($0)/Double(width)})
        }
        let area=raster.rows.reduce(0){total,row in total+stride(from:0,to:row.count,by:2).reduce(0){$0+row[$1+1]-row[$1]}}
        var hash=SHA256();hash.update(data:Data("rawRF-source-pixel-runs-v1:\(width)x\(height):".utf8))
        for (offset,row) in raster.rows.enumerated() where !row.isEmpty {
            for number in [raster.y+offset,row.count]+row {
                var value=UInt64(number).bigEndian
                withUnsafeBytes(of:&value){hash.update(data:Data($0))}
            }
        }
        return Capacity(rectNormalized:[Double(raster.x)/Double(width),Double(raster.y)/Double(height),Double(raster.width)/Double(width),Double(raster.height)/Double(height)],
            intervalRowsNormalized:rows,sourcePixelArea:area,sourcePixelRunsSHA256:hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
}
