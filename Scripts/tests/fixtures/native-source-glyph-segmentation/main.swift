import Foundation
import CoreGraphics
struct Fixture: Decodable {
 let name:String; let width:Int; let height:Int; let rgba:[UInt8]; let box:[Double]; let foreground:[Double]; let background:[Double]; let stroke:[Double]?; let backgroundConfidence:Double; let strokeConfidence:Double; let glyphSize:Double; let polygons:[[[Double]]]; let excluded:[[[Double]]]
}
let inputs=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
var results:[[String:Any]]=[]
for f in inputs {
 let palette=NativeSourceGlyphSegmentation.Palette(foreground:f.foreground,background:f.background,stroke:f.stroke,backgroundConfidence:f.backgroundConfidence,strokeConfidence:f.strokeConfidence)
 let options=NativeSourceGlyphSegmentation.Options(polygons:f.polygons.map{$0.map{CGPoint(x:$0[0],y:$0[1])}},excludedPolygons:f.excluded.map{$0.map{CGPoint(x:$0[0],y:$0[1])}},glyphSize:f.glyphSize,conservative:true)
 let r=NativeSourceGlyphSegmentation.forcedTextMask(rgba:f.rgba,width:f.width,height:f.height,box:CGRect(x:f.box[0],y:f.box[1],width:f.box[2],height:f.box[3]),palette:palette,options:options)
 var out:[String:Any]=["name":f.name]
 if let r { out["forced"]=["mask":r.mask,"core":r.sourceCoreCandidateMask,"outline":r.sourceOutlineCandidateMask,"counts":[r.sourceCorePixels,r.sourceComponents,r.sourceCoreCandidateCount,r.sourceCoreCandidateCovered,r.sourceOutlineCandidateCount,r.sourceOutlineCandidateCovered]] }
 else {out["forced"]=NSNull()}
 if let r=NativeSourceGlyphSegmentation.neutralSourceInkMask(rgba:f.rgba,width:f.width,height:f.height,vertical:true) {out["neutral"]=["mask":r.mask,"dense":r.denseSurfaceRecovered]}
 else {out["neutral"]=NSNull()}
 if let r=NativeSourceGlyphSegmentation.geometryMask(width:f.width,height:f.height,polygons:options.polygons,excluded:options.excludedPolygons,margin:7) {out["ownership"]=["mask":r.mask,"core":r.core]}
 else {out["ownership"]=NSNull()}
 let colored=NativeSourceGlyphSegmentation.coloredSourceInkMask(rgba:f.rgba,width:f.width,height:f.height,palette:palette)
 out["colored"]=["reason":colored.reason,"mask":colored.mask as Any? ?? NSNull(),"fill":colored.fill as Any? ?? NSNull(),"counts":[colored.erased,colored.strokeAdded,colored.enclosedFill,colored.fringeAdded,colored.haloAdded],"outlineInterior":colored.outlineInterior,"accepted":colored.acceptedCount as Any? ?? colored.accepted.map { c in ["box":[c.box.minX,c.box.minY,c.box.width,c.box.height],"pixels":c.pixels] },"rejected":colored.rejected.map { c in ["box":[c.box.minX,c.box.minY,c.box.width,c.box.height],"pixels":c.pixels] },"solid":colored.solid as Any? ?? NSNull(),"rim":colored.rim as Any? ?? NSNull()]
 func boxes(_ input:[CGRect])->[[CGFloat]] {input.map{[$0.minX,$0.minY,$0.width,$0.height]}}
 let rect=CGRect(x:f.box[0],y:f.box[1],width:f.box[2],height:f.box[3])
 let end=NativeSourceGlyphSegmentation.rowEndMarks(rgba:f.rgba,width:f.width,height:f.height,box:rect,glyph:f.glyphSize,palette:palette,vertical:true,side:.end)
 let start=NativeSourceGlyphSegmentation.rowEndMarks(rgba:f.rgba,width:f.width,height:f.height,box:rect,glyph:f.glyphSize,palette:palette,vertical:true,side:.start,allowDotRun:true)
 out["ends"]=["rects":boxes(end.rects),"open":end.open];out["starts"]=["rects":boxes(start.rects),"open":start.open]
 out["dots"]=boxes(NativeSourceGlyphSegmentation.adjacentDotRun(rgba:f.rgba,width:f.width,height:f.height,box:rect,glyph:f.glyphSize,palette:palette))
 let raw=(0..<(f.width*f.height)).map{index -> UInt8 in (0..<3).map{abs(Double(f.rgba[index*4+$0])-f.foreground[$0])}.max()! <= 40 ? 1:0}
 out["ruby"]=boxes(NativeSourceGlyphSegmentation.inferVerticalRuby(raw:raw,rgba:f.rgba,width:f.width,height:f.height,box:rect,background:f.background))
 if let grid=NativeSourceGlyphSegmentation.ruledGridRestore(rgba:f.rgba,width:f.width,height:f.height,box:rect,vertical:true) {out["grid"]=["rgba":grid.rgba,"safe":grid.layoutSafe,"readable":grid.readableRules,"counts":[grid.erased,grid.components],"rules":grid.rules,"paper":grid.paper]}
 else {out["grid"]=NSNull()}
 results.append(out)
}
try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
