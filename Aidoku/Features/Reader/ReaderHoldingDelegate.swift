//
//  ReaderHoldingDelegate.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/16/22.
//

import Foundation
import AidokuRunner
import UIKit

protocol ReaderHoldingDelegate: AnyObject {
    var barsHidden: Bool { get }

    func hideBars()

    func getNextChapter() -> AidokuRunner.Chapter?
    func getPreviousChapter() -> AidokuRunner.Chapter?
    func getNextChapter(after chapter: AidokuRunner.Chapter) -> AidokuRunner.Chapter?
    func getPreviousChapter(before chapter: AidokuRunner.Chapter) -> AidokuRunner.Chapter?
    func setChapter(_ chapter: AidokuRunner.Chapter)

    func setCurrentPage(_ page: Int, position: Double?)
    func setCurrentPages(_ pages: ClosedRange<Int>)
    func setPages(_ pages: [Page])
    func displayPage(_ page: Int) // show page on toolbar but don't set it as current page
    func setSliderOffset(_ offset: CGFloat)
    func setCompleted()
    func translationVisibilityDidChange()
    @MainActor
    func prepareCachedTranslationForDisplay(
        image: UIImage, page: Page,
        geometry: @escaping @MainActor () -> ReaderTranslationImageGeometry?
    ) async throws -> ReaderTranslationPreparedImage?
}

extension ReaderHoldingDelegate {
    func translationVisibilityDidChange() {}
    @MainActor
    func prepareCachedTranslationForDisplay(
        image: UIImage, page: Page,
        geometry: @escaping @MainActor () -> ReaderTranslationImageGeometry?
    ) async throws -> ReaderTranslationPreparedImage? { nil }
    func getNextChapter(after chapter: AidokuRunner.Chapter) -> AidokuRunner.Chapter? { nil }
    func getPreviousChapter(before chapter: AidokuRunner.Chapter) -> AidokuRunner.Chapter? { nil }
}
