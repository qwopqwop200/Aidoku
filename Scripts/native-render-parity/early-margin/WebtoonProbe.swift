import Foundation
import CoreGraphics
import ImageIO
@main struct WebtoonProbe {
 static func main() throws {
 let root=CommandLine.arguments[1],p=URL(fileURLWithPath:root).appendingPathComponent("build/native-render-parity/verify-image-build32-snapshot/webtoon-offscreen")
 let provider=try Data(contentsOf:p.appendingPathComponent("source.png"))
 let src=CGImageSourceCreateWithData(provider as CFData,nil)!,image=CGImageSourceCreateImageAtIndex(src,0,nil)!
 var items=try JSONDecoder().decode([NativeTranslationLayoutItem].self,from:Data(contentsOf:p.appendingPathComponent("web-layout.json")))
 let n=try JSONSerialization.jsonObject(with:Data(contentsOf:p.appendingPathComponent("native-final-layout.json"))) as! [String:Any]
 let cards=n["cards"] as! [[String:Any]]
 for i in items.indices {
 let growth=cards[i]["plateGrowth"] as! [String:Any],entry=growth["entering"] as! [String:Any],r=entry["rect"] as! [Double]
 let font=entry["font"] as! Double,ratio=items[i].lineHeight/items[i].fontSize
 items[i].x=r[0];items[i].y=r[1];items[i].width=r[2];items[i].height=r[3];items[i].fontSize=font;items[i].lineHeight=font*ratio
 if i<2 { items[i].paddingLeft=0;items[i].paddingRight=0;items[i].paddingTop=0;items[i].paddingBottom=0 }
 }
 let frame=CGRect(x:125,y:0,width:140,height:700)
 let layout=NativeTranslationLayout(imageSize:CGSize(width:480,height:2400),sourceRect:frame,viewport:CGSize(width:390,height:700),items:items)
 var settings=IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:3,subtitleContextSentences:0);settings.preserveSourceColors=true
 let restored=try NativeTranslationRestoration.prepare(image:image,layout:layout,settings:settings)
 let session=NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:restored,settings:settings,sourceImage:image)
 var rows:[[String:Any]]=[]
 for (i,item) in items.enumerated() {
 guard let patch=restored.patches.last(where:{$0.itemID == item.id}) else { continue }
 let context=session.context

 var row:[String:Any]=["id":item.id,"patchQuality":patch.surfaceQuality as Any? ?? NSNull(),"candidateQuality":patch.candidate?.surfaceQuality as Any? ?? NSNull(),"patchRect":[patch.rect.minX,patch.rect.minY,patch.rect.width,patch.rect.height],"readerBefore":context.reader.exteriorBudget,"sourceSample":restored.appearances[item.id]?.sourceSample as Any? ?? NSNull()]
 if i<2 {
 let proposed:[Double]=i==0 ? [131,2,107,248,28.25]:[210.046875,191.6875,52.5,302.59375,11.25]
 var target=context.resized(item,size:proposed[4]);target.x=proposed[0];target.y=proposed[1];target.width=proposed[2];target.height=proposed[3]
 target.paddingTop=0;target.paddingBottom=0;target.paddingLeft=0;target.paddingRight=0;target.typesettingText=nil
 let candidate=context.words(target,maxLines:8,strict:true) ?? context.candidate(target)
 var budget=65_536
 row["target"] = ["text":candidate.item.typesettingText as Any? ?? NSNull(),"fits":context.contentFits(candidate),"ink":[candidate.inkFrame.minX,candidate.inkFrame.minY,candidate.inkFrame.width,candidate.inkFrame.height],"surface":context.inspectedSurface(candidate,expands:true,allowExterior:true,margin:CGSize(width:target.fontSize*0.1,height:target.fontSize*0.1),lookupBudget:&budget) as Any? ?? NSNull(),"budget":budget] as [String:Any]
 if let grown=session.grow(item:item,others:items,cap:.infinity,strict:false) { row["grown"]=["font":grown.fontSize,"rect":[grown.x,grown.y,grown.width,grown.height]] } else { row["grown"]=NSNull() }
 }
 row["readerAfter"] = context.reader.exteriorBudget
 rows.append(row)
 }
 let out=p.deletingLastPathComponent().appendingPathComponent("webtoon-source-growth-host.json")
 try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:out)
 print(out.path)
 }
}
