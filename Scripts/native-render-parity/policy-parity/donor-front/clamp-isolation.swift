import Foundation
struct NativeRestorationPixels {
 static func clamp(_ value:Double)->UInt8 { value.isNaN || value<=0 ? 0 : value>=255 ? 255 : UInt8(value.rounded(.toNearestOrEven)) }
}
