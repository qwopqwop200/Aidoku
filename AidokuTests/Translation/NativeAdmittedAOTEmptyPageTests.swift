import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeAdmittedAOTEmptyPageTests {
    @available(iOS 16.0, *)
    private func fixture(masked: Bool) throws -> (CGImage, [UInt8], NativeAdmittedAOTPageRoute.Inventory,
                                                NativeAdmittedAOTPageRoute.Admission) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let source = try #require(image.cgImage)
        let bytes = try NativeAdmittedAOTPageRoute.rgba(source)
        var mask = [UInt8](repeating: 0, count: source.width * source.height)
        if masked { mask[0] = 1 }
        let inventory = NativeAdmittedAOTPageRoute.Inventory(
            owners: [], language: "ko", settingsRevision: "test-settings", ownershipPolicyRevision: "test-owners")
        let admission = NativeAdmittedAOTPageRoute.Admission(
            sourceRGBA256: NativeAdmittedAOTPageRoute.digest(Data(bytes)),
            binaryMask256: NativeAdmittedAOTPageRoute.digest(Data(mask)),
            inventory256: try NativeAdmittedAOTPageRoute.inventoryIdentity(inventory),
            maskPolicyRevision: "test-mask")
        return (source, mask, inventory, admission)
    }

    @available(iOS 16.0, *)
    @Test func emptyPagePreservesPixelsWithoutInstalledModelOrInference() async throws {
        let (source, mask, inventory, admission) = try fixture(masked: false)
        let result = try await NativeAdmittedAOTPageRoute.shared.render(
            source: source, binaryMask: mask, admission: admission, current: inventory,
            installedModelURL: nil, enabled: true)
        #expect(try NativeAdmittedAOTPageRoute.rgba(result.final) == NativeAdmittedAOTPageRoute.rgba(source))
        let audit = try #require(JSONSerialization.jsonObject(with: result.audit) as? [String: Any])
        #expect(audit["inferenceCalls"] as? Int == 0)
    }

    @available(iOS 16.0, *)
    @Test func nonemptyRemovalWithoutTranslationInventoryIsRejectedBeforeModelLoading() async throws {
        let (source, mask, inventory, admission) = try fixture(masked: true)
        do {
            _ = try await NativeAdmittedAOTPageRoute.shared.render(
                source: source, binaryMask: mask, admission: admission, current: inventory,
                installedModelURL: nil, enabled: true)
            Issue.record("An admitted removal mask must not erase pixels without a translated owner inventory")
        } catch NativeAdmittedAOTPageRoute.Failure.invalidAdmission {
            // This failure must precede model resolution and inference.
        }
    }
}
