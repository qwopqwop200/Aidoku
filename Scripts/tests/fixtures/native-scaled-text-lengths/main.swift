import Foundation
let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let output=input.map { entry -> [Double] in
    let p=entry["padding"] as! [Double]
    let item=NativeTranslationLayoutItem(x:entry["x"] as! Double,y:entry["y"] as! Double,width:entry["width"] as! Double,height:entry["height"] as! Double,paddingTop:p[0],paddingRight:p[1],paddingBottom:p[2],paddingLeft:p[3])
    let used=NativeTranslationRenderer.usedScaledTextItem(item,scale:entry["scale"] as! Double)
    return [used.x,used.y,used.width,used.height,used.paddingTop,used.paddingRight,used.paddingBottom,used.paddingLeft]
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
