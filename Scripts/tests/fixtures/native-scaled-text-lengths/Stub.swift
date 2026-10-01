import Foundation
struct NativeTranslationLayoutItem {
    var x:CGFloat
    var y:CGFloat
    var width:CGFloat
    var height:CGFloat
    var paddingTop:CGFloat
    var paddingRight:CGFloat
    var paddingBottom:CGFloat
    var paddingLeft:CGFloat
    var rect:CGRect {CGRect(x:x,y:y,width:width,height:height)}
}
enum NativeTranslationRenderer {
    struct Card {var item:NativeTranslationLayoutItem;var textShift:CGPoint;var effectiveTextRotation:CGFloat}
    // PRODUCTION_USED_LAYOUT_ITEM
    static func rotatedBounds(_ rect:CGRect,about:CGRect,angle:CGFloat)->CGRect {rect}
}
