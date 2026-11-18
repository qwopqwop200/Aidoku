import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Per-transaction immutable source reuse. No persistent cache or color-policy change.
final class NativeBootstrapSourceReuse {
    typealias R = NativeTranslationRenderer
    enum ReuseError: Error { case sourceDescriptor, prefixMismatch }
    struct Stamp {
        let remaining: Int
        let spent: Int
        let exhausted: Bool
        let recording: Bool
        init(_ b: NativeOwnerExteriorBGPrediction.Budget) {
            remaining=b.remaining; spent=b.spent; exhausted=b.exhausted; recording=b.recording
        }
        func matches(_ b: NativeOwnerExteriorBGPrediction.Budget) -> Bool {
            remaining == b.remaining && spent == b.spent && exhausted == b.exhausted && recording == b.recording
        }
    }
    struct BudgetImage {
        let data: Data
        init?(_ b: NativeOwnerExteriorBGPrediction.Budget) {
            let value:[String:Any] = ["remaining":b.remaining,"spent":b.spent,"exhausted":b.exhausted,
                "recording":b.recording,"observations":b.observations,
                "charges":b.charges.map { [$0.cost,$0.count] }]
            guard let encoded=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else { return nil }
            data=encoded
        }
        func restore(_ b: NativeOwnerExteriorBGPrediction.Budget) throws {
            guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let remaining=value["remaining"] as? Int,let spent=value["spent"] as? Int,
                  let exhausted=value["exhausted"] as? Bool,let recording=value["recording"] as? Bool,
                  let observations=value["observations"] as? [String:[String:Any]],
                  let charges=value["charges"] as? [[Int]],charges.allSatisfy({ $0.count==2 }) else { throw ReuseError.prefixMismatch }
            b.remaining=remaining;b.spent=spent;b.exhausted=exhausted;b.recording=recording
            b.observations=observations;b.charges=charges.map { .init(cost:$0[0],count:$0[1]) }
        }
    }
    struct Entry {
        let id: String
        let owner: CGRect
        let panel: CGRect
        let frame: CGRect
        let beforePrimary: Stamp
        let beforeRetry: Stamp
        let beforeSurfacePixels: Int
        let primary: BudgetImage
        let retry: BudgetImage
        let surfacePixels: Int
        let surface: NativeTextBoxContainment.Surface?
        let override: [Double]?
    }
    static let metadataByteLimit = 4*1024*1024
    static let readerCacheByteLimit = 4_194_304*4
    private(set) var retainedMetadataBytes = 0
    private(set) var peakRetainedMetadataBytes = 0
    private(set) var prefixEnabled: Bool
    private(set) var metadataAbstention: String?
    private var prepared = false
    private var source: CGImage?
    private(set) var reader: NativeSourcePixelReader?
    private var styleImages: [CGImage] = []
    private var entries: [Int:Entry] = [:]
    private var order: [Int] = []
    private var cursor = 0
    private(set) var normalizations = 0
    private(set) var replayed = 0
    private(set) var normalizedImageReused = false
    private(set) var paletteIdentitiesIsolated = false
    init(ownerCount: Int) { prefixEnabled = ownerCount <= 64 }
    func prepare(image: UIImage?, visible: Bool) throws -> CGImage? {
        if prepared { normalizedImageReused=true; return source }
        prepared=true
        source = visible ? try R.restorationImage(image) : nil
        normalizations = visible && image != nil ? 1 : 0
        guard let source else { return nil }
        reader=NativeSourcePixelReader(image:source,preservesSamplingGeometry:true)
        // Old <=4MP/up passes reused the original object/cache. Preserve that behavior.
        if let original=image?.cgImage, original === source {
            styleImages=[source,source]
        } else {
            // Old normalized passes had DIFFERENT identities. Sharing a palette
            // cache would skip budget charges and alter later source predictions.
            // Distinct descriptors share identical normalized data, no raster/filter work.
            func descriptor() throws -> CGImage {
                guard let provider=source.dataProvider, let space=source.colorSpace,
                      let copy=CGImage(width:source.width,height:source.height,
                        bitsPerComponent:source.bitsPerComponent,bitsPerPixel:source.bitsPerPixel,
                        bytesPerRow:source.bytesPerRow,space:space,bitmapInfo:source.bitmapInfo,
                        provider:provider,decode:source.decode,shouldInterpolate:source.shouldInterpolate,
                        intent:source.renderingIntent) else { throw ReuseError.sourceDescriptor }
                return copy
            }
            let first=try descriptor(), second=try descriptor()
            guard first !== second, first !== source, second !== source else { throw ReuseError.sourceDescriptor }
            styleImages=[first,second];paletteIdentitiesIsolated=true
        }
        return source
    }
    func styleImage(secondPass: Bool) -> CGImage? {
        guard styleImages.count==2 else { return nil }
        return styleImages[secondPass ? 1 : 0]
    }
    func release() {
        reader?.release();reader=nil;entries.removeAll();order.removeAll();styleImages.removeAll();source=nil
        retainedMetadataBytes=0
    }
    func record(index: Int,id: String,owner: CGRect,panel: CGRect,frame: CGRect,
                beforePrimary: Stamp,beforeRetry: Stamp,beforeSurfacePixels: Int,
                primary: NativeOwnerExteriorBGPrediction.Budget,retry: NativeOwnerExteriorBGPrediction.Budget,
                surfacePixels: Int,surface: NativeTextBoxContainment.Surface?,override: [Double]?) {
        guard prefixEnabled, entries.count<64 else { return }
        func abstain(_ reason:String) {
            prefixEnabled=false;metadataAbstention=reason;entries.removeAll();order.removeAll();retainedMetadataBytes=0
        }
        guard let primaryImage=BudgetImage(primary),let retryImage=BudgetImage(retry) else { abstain("metadata-encoding");return }
        let spans=(surface?.spans.capacity ?? 0)*MemoryLayout<(CGFloat,CGFloat)>.stride
        let colors=(surface?.color?.capacity ?? 0)*MemoryLayout<Double>.stride
        let strings=id.utf8.count+(surface?.colorEvidence.utf8.count ?? 0)
        let scalars=MemoryLayout<Entry>.stride+2*MemoryLayout<Int>.stride+(override?.capacity ?? 0)*MemoryLayout<Double>.stride
        let logical=primaryImage.data.count+retryImage.data.count+spans+colors+strings+scalars
        guard logical<=Self.metadataByteLimit-retainedMetadataBytes else { abstain("metadata-byte-limit");return }
        retainedMetadataBytes+=logical;peakRetainedMetadataBytes=max(peakRetainedMetadataBytes,retainedMetadataBytes)
        entries[index]=Entry(id:id,owner:owner,panel:panel,frame:frame,
            beforePrimary:beforePrimary,beforeRetry:beforeRetry,beforeSurfacePixels:beforeSurfacePixels,
            primary:primaryImage,retry:retryImage,surfacePixels:surfacePixels,surface:surface,override:override)
        order.append(index)
    }
    func replay(index: Int,id: String,owner: CGRect,panel: CGRect,frame: CGRect,
                primary: NativeOwnerExteriorBGPrediction.Budget,retry: NativeOwnerExteriorBGPrediction.Budget,
                surfacePixels: inout Int) throws -> Entry? {
        guard prefixEnabled else { return nil }
        guard cursor<order.count, order[cursor]==index, let entry=entries[index],entry.id==id,
              entry.owner==owner, entry.panel==panel, entry.frame==frame,
              entry.beforePrimary.matches(primary),entry.beforeRetry.matches(retry),
              entry.beforeSurfacePixels==surfacePixels else { throw ReuseError.prefixMismatch }
        cursor+=1; replayed+=1
        try entry.primary.restore(primary); try entry.retry.restore(retry); surfacePixels=entry.surfacePixels
        return entry
    }
    var audit: [String:Any] {
        ["normalizations":normalizations,"sameNormalizedImageAcrossPasses":normalizedImageReused,
         "paletteIdentitiesIsolatedWhenOriginallyRenormalized":paletteIdentitiesIsolated,
         "sourcePrefixEntries":entries.count,"sourcePrefixesReplayed":replayed,
         "sourcePrefixOwnerLimit":64,"prefixEnabled":prefixEnabled,
         "retainedMetadataLogicalBytes":retainedMetadataBytes,"peakRetainedMetadataLogicalBytes":peakRetainedMetadataBytes,
         "metadataLogicalByteLimit":Self.metadataByteLimit,"metadataAbstention":metadataAbstention as Any? ?? NSNull(),
         "readerCacheLogicalByteLimit":Self.readerCacheByteLimit,
         "readerCacheLiveUpperBound":reader == nil ? 0 : Self.readerCacheByteLimit,
         "normalizedSourceBackingLogicalBytes":source.map { $0.bytesPerRow*$0.height } ?? 0,
         "metadataAccounting":
            "retained serialized budget Data + surface array capacities + strings + entry/order scalar storage; dictionary/allocator overhead measured by RSS, not a claimed heap byte bound",
         "budgetReplay":"exact sequential entry counters and immutable per-owner observations; no quota forgiveness",
         "readerLifetime":"one transaction, release once after both passes",
         "sourceFilterResolutionAndColorPolicyChanged":false,"persistentCacheAdded":false]
    }
}
