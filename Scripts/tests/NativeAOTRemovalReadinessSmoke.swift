import Foundation

@main struct NativeAOTRemovalReadinessSmoke {
    static func main() throws {
        let states: [(Int, Int, Int?, Bool, String)] = [
            (1, 2, 2, true, "replacement-ready"),
            (0, 2, 2, false, "source-only-input-no-active-translation"),
            (0, 0, 2, false, "ocr-present-layout-input-missing"),
            (0, 0, 0, false, "observed-empty-ocr-not-confirmed-text-free"),
            (0, 0, nil, false, "no-layout-input-ocr-unavailable")
        ]
        for (active, input, ocr, pixels, status) in states {
            let audit = try NativeAOTRemovalReadiness.audit(activeOwners: active, inputOwners: input,
                observedOCR: ocr, hasRemovalPixels: pixels)
            precondition(audit["status"] as? String == status)
            precondition(audit["emptyMaskIsQualityPass"] as? Bool == false)
        }
        do {
            _ = try NativeAOTRemovalReadiness.audit(activeOwners: 1, inputOwners: 1,
                observedOCR: 1, hasRemovalPixels: false)
            fatalError("Active translation with empty mask must not silently pass")
        } catch NativeAOTRemovalReadiness.Failure.translatedOwnersWithoutRemovalMask(let count) {
            precondition(count == 1)
        }
        print("PASS: 6 removal-readiness controls; no source-only erasure introduced")
    }
}
