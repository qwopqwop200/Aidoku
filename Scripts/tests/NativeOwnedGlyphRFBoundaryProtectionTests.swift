import Foundation

/// Synthetic production-helper test; no models, images, labels or provider.
/// Compile this file and NativeOwnedGlyphRFBoundaryProtection.swift together.
@main enum NativeOwnedGlyphRFBoundaryProtectionTests {
    typealias Helper = NativeOwnedGlyphRFBoundaryProtection

    struct Fixture {
        let width = 64
        let height = 64
        var rgb = [UInt8](repeating: 220, count: 64 * 64 * 3)
        var owned = [UInt8](repeating: 1, count: 64 * 64)
        var factory = [UInt8](repeating: 0, count: 64 * 64)
        var hard = [UInt8](repeating: 0, count: 64 * 64)
        var boundary = [UInt8](repeating: 0, count: 64 * 64)
        var probability = [Float](repeating: 0, count: 64 * 64)
        var text = [UInt8](repeating: 1, count: 64 * 64)
        var source = "source-rgb"
        var probabilitySource = "source-rgb"
        var ownerSource = "source-rgb"
        var factorySource = "source-rgb"
        var rfSource = "source-rgb"
        var owner = "translated-owner"
        var factoryOwner = "translated-owner"
        var textOwner = "translated-owner"
        var opaque = true
        var background = [220.0, 220, 220]
        var ink: [Double]?
        var cellArea = 1.0
        var font = 16.0

        init() {
            for y in 20..<32 {
                for x in 20..<24 {
                    let k = y * width + x
                    setRGB(k, [20, 20, 20])
                    factory[k] = 1
                    probability[k] = 0.9
                    if x == 21 { boundary[k] = 1 }
                }
            }
        }

        mutating func setRGB(_ index: Int, _ color: [UInt8]) {
            for channel in 0..<3 { rgb[index * 3 + channel] = color[channel] }
        }

        var input: Helper.Input {
            .init(width: width, height: height, rgb: rgb, owned: owned, factoryMask: factory,
                hardProtection: hard, balloonBoundary: boundary, probability: probability,
                textSupport: text, background: background, fontPixels: font,
                sourceRevision: source, probabilitySourceRevision: probabilitySource,
                ownerSourceRevision: ownerSource, factorySourceRevision: factorySource,
                rfSourceRevision: rfSource, ownerID: owner, factoryOwnerID: factoryOwner,
                textSupportOwnerID: textOwner, originalOpaque: opaque, chromaticInk: ink,
                probabilityCellArea: cellArea)
        }
    }

    static func main() async throws {
        let fixture = Fixture()
        let first = 20 * fixture.width + 20
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func noExemption(_ edit: (inout Fixture) -> Void) throws -> Bool {
            var test = fixture
            edit(&test)
            return try Helper.evaluate(test.input).boundaryExemptions.isEmpty
        }
        func fails(_ edit: (inout Fixture) -> Void, as expected: Helper.Failure) -> Bool {
            var test = fixture
            edit(&test)
            do { _ = try Helper.apply(test.input); return false }
            catch let error as Helper.Failure {
                switch (error, expected) {
                case (.invalidEvidence, .invalidEvidence), (.staleSource, .staleSource),
                     (.mismatchedOwner, .mismatchedOwner): return true
                default: return false
                }
            } catch { return false }
        }

        let originalRGB = fixture.rgb
        let repaired = try Helper.apply(fixture.input)
        check(repaired.audit.acceptedComponents == 1, "complete owned glyph accepted")
        check(repaired.audit.boundaryExemptions.count == 12, "only existing contour conflict pixels")
        check(repaired.mask.filter { $0 != 0 }.count == 48, "factory glyph retained through false boundary")
        check(repaired.mask.indices.allSatisfy { repaired.mask[$0] == 0 || fixture.factory[$0] != 0 }, "factory subset")
        check(fixture.rgb == originalRGB && fixture.factory[first] == 1, "original inputs immutable")

        check(try noExemption { $0.hard[first] = 1 }, "one hard contact vetoes entire component")
        var hardOverlap = fixture
        hardOverlap.hard[first + 1] = 1
        let protected = try Helper.apply(hardOverlap.input)
        check(protected.mask[first + 1] == 0 && protected.audit.hardVetoComponents == 1, "hard/RF overlap wins")
        check(try noExemption { $0.owned[first] = 0 }, "complete component crosses original ownership")
        check(try noExemption { $0.text[first] = 0 }, "complete component crosses RF nomination")
        check(try noExemption { $0.factory = $0.hard }, "RF rectangle alone cannot erase")
        check(try noExemption { $0.boundary = $0.hard }, "no boundary conflict")
        check(try noExemption { $0.probability = [Float](repeating: 0, count: 4096) }, "no independent DB support")
        check(try noExemption { $0.cellArea = 16 }, "upsampled DB pixels cannot invent detector cells")
        var sparseDB = fixture
        sparseDB.probability = [Float](repeating: 0, count: 4096)
        for x in 20..<24 { for y in 20..<22 { sparseDB.probability[y * 64 + x] = 0.9 } }
        check(try Helper.evaluate(sparseDB.input).acceptedComponents == 1, "DB core differs from outline occupancy")
        check(try noExemption { $0.factory[first] = 0; $0.factory[first + 1] = 0; $0.factory[first + 2] = 0 },
            "insufficient original factory coverage")

        var aa = fixture
        let shell = 25 * 64 + 24
        aa.setRGB(shell, [205, 205, 205]); aa.factory[shell] = 1; aa.boundary[shell] = 1
        aa.setRGB(shell + 1, [205, 205, 205]); aa.factory[shell + 1] = 1; aa.boundary[shell + 1] = 1
        let shellResult = try Helper.apply(aa.input)
        check(shellResult.mask[shell] == 255, "one original pixel AA shell")
        check(shellResult.mask[shell + 1] == 0, "no iterative AA expansion")
        aa.hard[shell] = 1
        check(try Helper.apply(aa.input).mask[shell] == 0, "hard shell remains protected")
        aa.hard[shell] = 0; aa.factory[shell] = 0
        check(try Helper.apply(aa.input).mask[shell] == 0, "AA cannot create new factory pixels")

        var chromatic = fixture
        for y in 20..<32 { for x in 20..<24 { chromatic.setRGB(y * 64 + x, [205, 20, 150]) } }
        check(try Helper.evaluate(chromatic.input).boundaryExemptions.isEmpty, "no guessed chromatic palette")
        chromatic.ink = [205, 20, 150]
        check(try Helper.evaluate(chromatic.input).boundaryExemptions.count == 12, "measured original chromatic palette")
        var reversed = fixture
        reversed.background = [20, 20, 20]
        reversed.rgb = [UInt8](repeating: 20, count: 4096 * 3)
        for y in 20..<32 { for x in 20..<24 { reversed.setRGB(y * 64 + x, [240, 240, 240]) } }
        check(try Helper.evaluate(reversed.input).boundaryExemptions.count == 12, "light ink on dark source")
        check(try noExemption { test in
            for y in 0..<64 {
                let k = y * 64 + 21
                test.setRGB(k, [20, 20, 20]); test.factory[k] = 1; test.boundary[k] = 1; test.probability[k] = 0.9
            }
        }, "complete structural line touching ROI edge rejected")
        check(try noExemption { $0.font = 2 }, "oversized component relative to measured font")

        for edit: (inout Fixture) -> Void in [
            { $0.probabilitySource = "stale" }, { $0.ownerSource = "stale" },
            { $0.factorySource = "stale" }, { $0.rfSource = "stale" }, { $0.source = "" }
        ] { check(fails(edit, as: .staleSource), "every evidence source must match") }
        check(fails({ $0.factoryOwner = "foreign" }, as: .mismatchedOwner), "foreign factory owner")
        check(fails({ $0.textOwner = "foreign" }, as: .mismatchedOwner), "foreign RF nomination owner")
        check(fails({ $0.owner = " " }, as: .mismatchedOwner), "blank owner")
        for edit: (inout Fixture) -> Void in [
            { $0.opaque = false }, { $0.probability[0] = .nan }, { $0.probability[0] = 1.01 },
            { $0.background = [0, 0] }, { $0.ink = [.infinity, 0, 0] },
            { $0.factory.removeLast() }, { $0.font = .nan }, { $0.cellArea = 0 }
        ] { check(fails(edit, as: .invalidEvidence), "malformed evidence fails closed") }

        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try Helper.evaluate(fixture.input); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        check(await cancelled.value, "bounded helper honors cancellation")
        print("{\"checks\":\(checks),\"failed\":0,\"modelCalls\":0,\"providerCalls\":0}")
    }
}
