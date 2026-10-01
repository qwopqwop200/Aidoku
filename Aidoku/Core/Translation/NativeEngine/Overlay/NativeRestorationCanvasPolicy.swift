import Foundation

/// DOM canvas completion and the source erasure certificate are independent.
/// This is the ordinary spatial producer's frozen1822–1823 contract; pixel
/// kernels keep their own stricter erasure proof unchanged.
enum NativeRestorationCanvasPolicy {
    static func isComplete(paintedCount: Int, preservedPixels: Int, preservedCore: Int) -> Bool {
        paintedCount > 0 && preservedPixels == 0 && preservedCore == 0
    }
}
