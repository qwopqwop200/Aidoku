@testable import Aidoku

// Test-only legacy browser reference.
import WebKit

/// Isolated document state retained only for the browser renderer and the web parity oracle.
enum ReaderTranslationDOM {
    @MainActor static let contentWorld = WKContentWorld.world(name: "AidokuReaderTranslation")
}
