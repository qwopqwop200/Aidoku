import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LibraryCategorySelectionBoundsTests {
    @Test(arguments: [-1, 1000], [false, true])
    func staleMenuRowDoesNotChangeSelectionOrCrash(row: Int, hasCategories: Bool) async throws {
        let saved = AppSettings.library.currentCategory.get()
        defer { AppSettings.library.currentCategory.set(saved) }
        let controller = LibraryViewController()
        controller.viewModel.categories = hasCategories ? ["Audit category"] : []
        controller.viewModel.filterGroups = []
        controller.viewModel.currentCategory = "Unchanged audit selection"
        // Use the actual nonisolated header delegate entry; its MainActor task
        // must reject both category and shifted/empty filter-group menu indexes.
        controller.optionSelected(IndexPath(row: row, section: 1))
        controller.optionSelected(IndexPath(row: row, section: 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.viewModel.currentCategory == "Unchanged audit selection")
        #expect(!controller.isViewLoaded, "Invalid selection must not start UI/library reload")
    }

    @Test func validCategorySelectionStillApplies() async throws {
        let saved = AppSettings.library.currentCategory.get()
        defer { AppSettings.library.currentCategory.set(saved) }
        let controller = LibraryViewController()
        controller.loadViewIfNeeded()
        // Finish initial source/category loading before installing the menu snapshot.
        try await Task.sleep(for: .milliseconds(200))
        controller.viewModel.categories = ["Audit first", "Audit second"]
        controller.viewModel.currentCategory = nil
        controller.optionSelected(IndexPath(row: 1, section: 1))
        let deadline = Date().addingTimeInterval(3)
        while controller.viewModel.currentCategory != "Audit second", Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.viewModel.currentCategory == "Audit second")
    }
}
