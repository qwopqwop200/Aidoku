import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct SourceBrowseSafetyTests {
    @Test func removingSourceSettingsPreservesSimilarlyNamedSources() {
        let key = "audit-source-" + UUID().uuidString
        let ownSetting = key + ".login.password"
        let siblingSetting = key + "-1.login.password"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: ownSetting)
            defaults.removeObject(forKey: siblingSetting)
        }
        defaults.set("own", forKey: ownSetting)
        defaults.set("sibling", forKey: siblingSetting)

        SourceManager.shared.removeSettings(from: key)

        #expect(defaults.string(forKey: ownSetting) == nil)
        #expect(defaults.string(forKey: siblingSetting) == "sibling")
    }

    @Test func emptyCarouselScrollDoesNotDivideByZero() {
        let carousel = CarouselCollectionView(frame: .zero, collectionViewFlowLayout: UICollectionViewFlowLayout())
        carousel.scrollViewDidScroll(carousel)
    }
}
