import Testing
@testable import Aidoku

struct FDATExactReuseAttestationTests {
    @Test func exactReviewedFDATCatalogEntryOnly() async throws {
        let catalog = await ModelManager.shared.bundledModels()
        let trusted = try #require(catalog.first { $0.file == "IllustrationJaNaiV3-FDATM.mlpackage" })
        #expect(ModelManager.matchesExactReuseCatalog(trusted, catalog: catalog))
        var missing = trusted; missing.bundledResource = nil
        var config = trusted; config.config = [:]
        var type = trusted; type.type = "image"
        var hash = trusted; hash.sha256 = String(repeating: "0", count: 64)
        var name = trusted; name.file = "Other.mlpackage"
        for altered in [missing, config, type, hash, name] {
            #expect(!ModelManager.matchesExactReuseCatalog(altered, catalog: catalog))
        }
        // Even a future/modified catalog cannot silently admit unreviewed FDAT weights.
        let changedCatalog = catalog.map { $0.file == trusted.file ? hash : $0 }
        #expect(!ModelManager.matchesExactReuseCatalog(hash, catalog: changedCatalog))
        for other in catalog where other.file != trusted.file && other.file != "SwinUNetV3Art2x.mlpackage" {
            #expect(!ModelManager.matchesExactReuseCatalog(other, catalog: catalog))
        }
    }
}
