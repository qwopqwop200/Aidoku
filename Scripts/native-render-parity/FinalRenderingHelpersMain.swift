import CoreGraphics
import Foundation
@main enum FinalRenderingHelpersMain {
    static func main() throws {
        let jobs=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
        let output=jobs.map { j -> Any in
            if j["operation"] as! String == "plate" {
                let b=j["bounds"] as! [Double]
                return NativeTranslationFinalRenderingHelpers.plateMeets(bounds:CGRect(x:b[0],y:b[1],width:b[2],height:b[3]),width:j["width"] as! Double,height:j["height"] as! Double,matrix:j["matrix"] as? [Double],ink:j["ink"] as! [Double])
            }
            if j["operation"] as! String == "turn" {
                let p=j["origin"] as! [Double],c=j["center"] as! [Double]
                if let v=NativeTranslationFinalRenderingHelpers.turnGloss(nodeOrigin:CGPoint(x:p[0],y:p[1]),angle:j["angle"] as? Double,center:CGPoint(x:c[0],y:c[1])) { return ["angle":v.angle,"origin":[Double(v.origin.x),Double(v.origin.y)]] as [String:Any] }
                return NSNull()
            }
            let safe=j["safe"] as! [UInt8],luminance=j["luminance"] as! [UInt8],frame=j["frame"] as! [Double],at=j["at"] as! [Double]
            let cache=NativeTranslationSurfacePool.Cache(budget:j["budget"] as! Int)
            let crop=NativeTranslationSurfacePool.Crop(safe:safe,luminance:luminance,width:j["width"] as! Int,height:j["height"] as! Int,x:at[0],y:at[1],sx:at[2],sy:at[3],imageWidth:at[4],imageHeight:at[5],frameWidth:frame[0],frameHeight:frame[1])
            guard let pool=cache.pool(crop,safeIdentity:"safe",luminanceIdentity:"lum") else { return NSNull() }
            if j["operation"] as! String == "range" {
                var budget=j["lookup"] as! Int
                let boxes=(j["boxes"] as! [[Int]]).map { NativeTranslationSurfacePool.Box(left:$0[0],top:$0[1],right:$0[2],bottom:$0[3]) }
                let range=cache.range(pool,boxes:boxes,lookupBudget:&budget)
                return ["range":range as Any? ?? NSNull(),"lookup":budget,"budget":cache.remaining,"pixels":cache.pixels,"tiles":pool.tiles,"low":pool.low as Any? ?? NSNull(),"high":pool.high as Any? ?? NSNull()] as [String:Any]
            }
            var actions:[Any]=[]
            for step in j["steps"] as! [[String:Any]] {
                let b=step["box"] as! [Int]
                let ready=cache.ready(pool,cells:.init(left:b[0],top:b[1],right:b[2],bottom:b[3]),build:step["build"] as! Bool)
                actions.append(["ready":ready,"budget":cache.remaining,"pixels":cache.pixels,"tiles":pool.tiles,"low":pool.low as Any? ?? NSNull(),"high":pool.high as Any? ?? NSNull()] as [String:Any])
            }
            let cached=cache.pool(crop,safeIdentity:"safe",luminanceIdentity:"lum") === pool
            return ["k":pool.k,"cw":pool.columns,"ch":pool.rows,"tw":pool.tileColumns,"th":pool.tileRows,"actions":actions,"cached":cached] as [String:Any]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
    }
}
