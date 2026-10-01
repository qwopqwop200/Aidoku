import Foundation
@main enum Main {
 static func main() throws {
 let inputs = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
 let results = inputs.map { j -> [String:Any] in
 let w=j["width"] as! Int,h=j["height"] as! Int,safe=(j["safe"] as! [Int]).map(UInt8.init),lum=(j["luminance"] as! [Int]).map(UInt8.init),ratio=j["ratio"] as! Double
 let cache=NativeTranslationSurfacePool.Cache(budget:j["poolBudget"] as! Int)
 let crop=NativeTranslationSurfacePool.Crop(safe:safe,luminance:lum,width:w,height:h,x:40,y:40,sx:1,sy:1,imageWidth:Double(w+80),imageHeight:Double(h+80),frameWidth:Double(w)/ratio,frameHeight:Double(h)/ratio)
 let pool=cache.pool(crop,safeIdentity:"safe",luminanceIdentity:"lum")!
 let boxes=(j["boxes"] as! [[Int]]).map { NativeTranslationSurfacePool.Box(left:$0[0],top:$0[1],right:$0[2],bottom:$0[3]) }
 var budget=j["lookup"] as! Int
 let ext=j["exterior"] as! [Double]
 let range=cache.range(pool,boxes:boxes,lookupBudget:&budget) { x,y in
 let rgb=ext;let linear=rgb.map {v -> Double in let c=v/255;return c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4)}
 if j["reject"] as! Bool && x < 0 { return nil }
 return 255*(0.2126*linear[0]+0.7152*linear[1]+0.0722*linear[2])
 }
 return ["range":range as Any? ?? NSNull(),"lookup":budget,"poolBudget":cache.remaining,"pixels":cache.pixels,"tiles":pool.tiles.map(Int.init)]
 }
 FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]))
 }
}
