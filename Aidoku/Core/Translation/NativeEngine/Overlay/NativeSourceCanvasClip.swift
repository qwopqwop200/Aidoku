import CoreGraphics
import Foundation

/// Display-only clip-path transport for source repair canvases. The raw
/// cleanup bounds and DOM-used canvas rectangle remain export/raster metadata.
enum NativeSourceCanvasClip {
    /// WebKit uses a device-snapped reference box for the basic shape. This is
    /// not a statement about its image raster draw frame or saved mask frame.
    /// The caller supplies a finite DOM rectangle with positive raw dimensions;
    /// liveClip validates that precondition before calling this primitive.
    static func referenceRect(domRect: CGRect, deviceScale: CGFloat) -> CGRect {
        guard deviceScale.isFinite, deviceScale > 0 else { return domRect }
        func snap(_ value: CGFloat) -> CGFloat {
            CGFloat(Float(floor(Double(value) * Double(deviceScale) + 0.5) / Double(deviceScale)))
        }
        return CGRect(x:snap(domRect.origin.x),y:snap(domRect.origin.y),
                      width:snap(domRect.size.width),height:snap(domRect.size.height))
    }

    /// `nil` means CSS `none`; a zero-area rectangle means an empty shape.
    /// Fixed pixel insets are measured against the authored canvas, parsed as
    /// CSS Float32 lengths, then applied to the display reference box. They
    /// are neither percentages nor individually rounded LayoutUnits.
    static func liveClip(authoredRect: CGRect, domRect: CGRect,
                         cleanupClip: CGRect?, deviceScale: CGFloat) -> CGRect? {
        guard let clip = cleanupClip else { return nil }
        guard [authoredRect.origin.x,authoredRect.origin.y,authoredRect.size.width,authoredRect.size.height,
               domRect.origin.x,domRect.origin.y,domRect.size.width,domRect.size.height,
               clip.origin.x,clip.origin.y,clip.size.width,clip.size.height,deviceScale].allSatisfy(\.isFinite),
              authoredRect.size.width > 0,authoredRect.size.height > 0,
              domRect.size.width > 0,domRect.size.height > 0,deviceScale > 0 else { return .zero }
        // Literal aidokuCleanupClip1115–1119 arithmetic, before CSS parsing.
        let left=max(0,clip.origin.x-authoredRect.origin.x)
        let top=max(0,clip.origin.y-authoredRect.origin.y)
        let right=max(0,authoredRect.origin.x+authoredRect.size.width-clip.origin.x-clip.size.width)
        let bottom=max(0,authoredRect.origin.y+authoredRect.size.height-clip.origin.y-clip.size.height)
        if left >= authoredRect.size.width || right >= authoredRect.size.width ||
            top >= authoredRect.size.height || bottom >= authoredRect.size.height { return .zero }
        if left == 0 && top == 0 && right == 0 && bottom == 0 { return nil }
        let reference=referenceRect(domRect:domRect,deviceScale:deviceScale)
        let x=Float(reference.origin.x),y=Float(reference.origin.y)
        let l=x+Float(left),t=y+Float(top)
        let r=x+Float(reference.size.width)-Float(right)
        let b=y+Float(reference.size.height)-Float(bottom)
        guard l < r,t < b else { return .zero }
        return CGRect(x:CGFloat(l),y:CGFloat(t),width:CGFloat(r-l),height:CGFloat(b-t))
    }
}
