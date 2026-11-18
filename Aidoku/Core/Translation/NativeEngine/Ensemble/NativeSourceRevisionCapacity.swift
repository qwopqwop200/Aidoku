import CoreGraphics
import Foundation

/// A producer-bound complete-source revision must not borrow unverified
/// horizontal space merely because a longer translated line is easier to fit.
enum NativeSourceRevisionCapacity {
    enum Failure: Error { case missingOwner, invalidSource, missingLayoutContract }

    static func constrain(_ page: Ensemble100Page, ownerIDs: Set<String>) throws -> Ensemble100Proposal {
        guard !ownerIDs.isEmpty else { return .init(items: page.items, audit: ["status": "not-required"]) }
        var output = page.items, found = Set<String>()
        let canvas = CGRect(origin: .zero, size: page.viewport)
        for index in output.indices {
            guard let id = output[index]["id"] as? String, ownerIDs.contains(id) else { continue }
            guard found.insert(id).inserted else { throw Failure.missingOwner }
            guard let source = output[index]["sourceBounds"] as? [Double], source.count == 4,
                  source.allSatisfy(\.isFinite), source[2] > 0, source[3] > 0 else { throw Failure.invalidSource }
            let box = CGRect(x: source[0] * page.viewport.width, y: source[1] * page.viewport.height,
                width: source[2] * page.viewport.width, height: source[3] * page.viewport.height)
            guard canvas.insetBy(dx: -1e-6, dy: -1e-6).contains(box) else { throw Failure.invalidSource }
            guard var contract = output[index]["sourceNearLayout"] as? [String: Any],
                  contract["boundsIncludeHalo"] as? Bool == true else { throw Failure.missingLayoutContract }
            // A source rectangle encloses ink, not the balloon's curved rim.
            // Keep a conservative interior reserve before fitting the complete
            // paragraph (including its mandatory halo); never expand erasure.
            let reserve = min(box.width, box.height) * 0.1
            let capacity = box.insetBy(dx: reserve, dy: reserve)
            let values = [Double(capacity.minX), Double(capacity.minY), Double(capacity.width), Double(capacity.height)]
            contract["allowedRect"] = values
            contract["preferredRect"] = values
            contract["anchorRect"] = values
            contract["maxCenterDrift"] = 0.0
            contract["capacity"] = "validated-source-revision-own-envelope;includes-mandatory-halo"
            contract["sourceRevisionOwnCapacityRequired"] = true
            contract["sourceRevisionInteriorReservePixels"] = Double(reserve)
            output[index]["sourceNearLayout"] = contract
            output[index]["sourceRevisionOwnCapacityRequired"] = true
        }
        guard found == ownerIDs else { throw Failure.missingOwner }
        return .init(items: output, audit: ["status": "source-revision-capacity-constrained",
            "owners": found.sorted(), "sourceGeometryChanged": false, "targetsChanged": false,
            "masksChanged": false, "balloonContainmentCertified": false,
            "authority": "immutable own source envelope; final glyph and mandatory halo still require native certification"])
    }
}
