import Foundation
import CoreGraphics
enum NativeTranslationSourceStylePostPolish {
 struct Panel { var rect:CGRect;var background:[Double];var radius:Double=3;var coverage:[CGRect];var sourceErasure=false;var clipped=false;var isFlat=true;var captionUnionClipped=false;var hasForeignChildren=false;var rotated=false;var sourceFrameImage:CGImage?;var sourceFrameLineCount=0;var balloonInteriorClipped:Int? }
 static func sourceColorContrast(_ color:[Double],panel:[Double])->Double{fatalError("unused color branch")}
 static func luminance(_ color:[Double])->Double{fatalError("unused color branch")}
 static func adjustInkForContrast(_ color:[Double],contrast:([Double])->Double,target:Double)->[Double]{fatalError("unused color branch")}
}
