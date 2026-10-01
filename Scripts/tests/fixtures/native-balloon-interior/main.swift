import Foundation
import CoreGraphics
func rect(_ v:[Double])->CGRect {CGRect(x:v[0],y:v[1],width:v[2],height:v[3])}
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let output:[[String:Any]]=fixtures.map {f in
    let estimator=NativeBalloonInteriorEstimator(pixelBudget:f["budget"] as? Int ?? 3_000_000)
    var reads:[[Double]]=[],results:[Any]=[]
    for _ in 0..<(f["repeat"] as? Int ?? 1) {
        let result=estimator.estimate(sourceRects:(f["own"] as! [[Double]]).map(rect),unitMemberCount:f["members"] as? Int ?? 0,sourceUnion:(f["union"] as? [Double]).map(rect),frame:rect(f["frame"] as! [Double]),sourceFontSize:f["glyph"] as? Double,reader:{crop,w,h in
            reads.append([crop.minX,crop.minY,crop.width,crop.height,Double(w),Double(h)])
            return (f["rgba"] as! [Int]).map(UInt8.init)
        })
        if let result {results.append(["w":result.width,"h":result.height,"k":result.scale,"fill":result.fill.map(Int.init),"paper":result.surfaceRGB,"tight":result.tight,"outside":(f["queries"] as! [[Double]]).map {result.outside(rect($0))}])}else {results.append(NSNull())}
    }
    return ["name":f["name"]!,"reads":reads,"remaining":estimator.remainingPixels,"results":results]
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
