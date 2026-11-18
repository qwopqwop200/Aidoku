import CoreGraphics
import Foundation

/// One actual recognizer row, in original row order. Geometry is translated,
/// never clipped: a member may extend outside the crop, but not the source page.
/// This is an observation (possibly a whole line), not inferred glyph tokens.
struct SourceWordEvidence: Sendable {
    let text: String
    let sourceIndex: Int
    let bbox: CGRect // envelope of the observed polygon, in crop-local source pixels
    let polygon: [CGPoint]
}

/// One original-resolution source crop throughout the native inference graph.
/// All polygons/bbox are LOCAL crop pixels; crop/pageSize restore page position.
/// RF/seg/OCR are row-major pixel-interleaved source observations, never labels.
struct SourceNativeInput: Sendable {
    let width: Int
    let height: Int
    let rgb: [UInt8]
    let rf: [Float] // 27 channels; frozen Float16-quantized RF ABI, promoted to Float
    let coarseRF: [Float] // 4 channels; frozen UInt8-step RF ABI
    let affinityScores: [Float] // 5 UNQUANTIZED source owner affinities
    let rfModelWeightsSHA256: String
    let memberPolygons: [[CGPoint]]
    let mergedPolygon: [CGPoint]
    let bbox: CGRect
    let fontPriorSourcePixels: Double
    let crop: CGRect // original page-pixel integral crop
    let pageSize: CGSize
    let sourceIdentity: String // binding/grouping only; never a model feature
    let sourceText: String
    let confidence: Double?
    let role: String?
    var wordEvidence: [SourceWordEvidence] = [] // absent recognizer evidence stays empty
    /// Row-major 0/1 support of actual primary AND boundary observations.
    /// Empty means unknown, never implicitly all-valid. Independent of ink masks.
    var observationValid: [UInt8] = []
    var primary: [Float] = []
    var boundary: [Float] = []
    var rawNative: [UInt8] = []
    var completed: [UInt8] = []
    var ownMask: [UInt8] = []
    var contextMask: [UInt8] = []
    var ocr: [Float] = [] // 8 confidence/availability channels

    enum Failure: Error { case invalidSource, invalidPredictions }

    /// Opt-in prerequisite for future weight inference; legacy mask consumers
    /// retain validate() semantics and need not manufacture missing observations.
    /// Binary base and directional correction do not require words. Only word-
    /// specific consumers pass true; absent words are never reconstructed.
    func validateWeightObservations(requireWordEvidence: Bool = false) throws {
        try validate()
        let n = width * height
        guard rawNative.count == n, rawNative.allSatisfy({ $0 == 0 || $0 == 1 || $0 == 255 }),
              observationValid.count == n, observationValid.allSatisfy({ $0 == 0 || $0 == 1 }),
              observationValid.contains(1), !requireWordEvidence || !wordEvidence.isEmpty else { throw Failure.invalidPredictions }
    }

    func validate(requirePredictions: Bool = true) throws {
        guard width>0,height>0,width<=1_500_000/height,rgb.count==width*height*3,
              rf.count==width*height*27,coarseRF.count==width*height*4,affinityScores.count==5,
              rf.allSatisfy({$0.isFinite && (0...1.001).contains($0)}),
              coarseRF.allSatisfy({$0.isFinite && (0...1.001).contains($0)}),
              affinityScores.allSatisfy({$0.isFinite && (0...1.001).contains($0)}),
              rfModelWeightsSHA256==NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
              fontPriorSourcePixels.isFinite,fontPriorSourcePixels>0,
              crop==crop.integral,crop.width==CGFloat(width),crop.height==CGFloat(height),
              crop.minX>=0,crop.minY>=0,crop.maxX<=pageSize.width,crop.maxY<=pageSize.height,
              !memberPolygons.isEmpty,memberPolygons.count<=256,
              (memberPolygons+[mergedPolygon]).allSatisfy({ polygon in
                  (3...256).contains(polygon.count) && polygon.allSatisfy {
                      $0.x.isFinite && $0.y.isFinite && $0.x>=0 && $0.y>=0 && $0.x<=CGFloat(width) && $0.y<=CGFloat(height)
                  }
              }),bbox.minX.isFinite,bbox.minY.isFinite,bbox.width.isFinite,bbox.height.isFinite,
              bbox.width>0,bbox.height>0,!sourceIdentity.isEmpty else {throw Failure.invalidSource}
        guard wordEvidence.count <= 256, wordEvidence.reduce(0, { $0 + $1.text.utf8.count }) <= 262_144,
              wordEvidence.allSatisfy({ word in
                  let b = word.bbox.offsetBy(dx: crop.minX, dy: crop.minY)
                  guard (3...256).contains(word.polygon.count),
                        word.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
                  let xs = word.polygon.map(\.x), ys = word.polygon.map(\.y)
                  // Compare all four edges in source pixels, allowing only
                  // coordinate roundoff, not a shifted or resized pairing.
                  let tolerance: CGFloat = 1e-5
                  guard abs(word.bbox.minX - xs.min()!) <= tolerance,
                        abs(word.bbox.maxX - xs.max()!) <= tolerance,
                        abs(word.bbox.minY - ys.min()!) <= tolerance,
                        abs(word.bbox.maxY - ys.max()!) <= tolerance else { return false }
                  return word.sourceIndex >= 0 && word.text.utf8.count <= 65_536 &&
                      b.minX.isFinite && b.minY.isFinite && b.width.isFinite && b.height.isFinite &&
                      b.width > 0 && b.height > 0 && b.minX >= 0 && b.minY >= 0 &&
                      b.maxX <= pageSize.width && b.maxY <= pageSize.height &&
                      word.polygon.allSatisfy {
                          $0.x + crop.minX >= 0 && $0.y + crop.minY >= 0 &&
                          $0.x + crop.minX <= pageSize.width && $0.y + crop.minY <= pageSize.height
                      }
              }) else { throw Failure.invalidSource }
        guard requirePredictions else {return}
        let n=width*height
        guard primary.count==n,boundary.count==n,ownMask.count==n,contextMask.count==n,ocr.count==n*8,
              primary.allSatisfy({$0.isFinite && (0...1).contains($0)}),
              boundary.allSatisfy({$0.isFinite && (0...1).contains($0)}),
              ocr.allSatisfy({$0.isFinite && (0...1.001).contains($0)}),
              ownMask.allSatisfy({$0==0 || $0==1 || $0==255}),
              contextMask.allSatisfy({$0==0 || $0==1 || $0==255}),ownMask.contains(where:{$0 != 0}),
              zip(ownMask,contextMask).allSatisfy({$0==0 || $1 != 0}) else {throw Failure.invalidPredictions}
    }
}
