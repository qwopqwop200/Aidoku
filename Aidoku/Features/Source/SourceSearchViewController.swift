//
//  SourceSearchViewController.swift
//  Aidoku
//
//  Created by Skitty on 11/19/25.
//

import AidokuRunner
import Combine
import SwiftUI

class SourceSearchViewController: MangaCollectionViewController {
    let viewModel: SourceSearchViewModel

    var searchText: String = ""
    var enabledFilters: [FilterValue] = [] {
        didSet {
            if viewModel.hasAppeared && enabledFilters != oldValue {
                viewModel.loadManga(
                    searchText: searchText,
                    filters: enabledFilters,
                    force: true
                )
            }
        }
    }

    override var entries: [AidokuRunner.Manga] {
        get { viewModel.entries }
        set { viewModel.entries = newValue }
    }
    override var bookmarkedItems: Set<String> {
        get { viewModel.bookmarkedItems }
        set { viewModel.bookmarkedItems = newValue }
    }

    init(source: AidokuRunner.Source) {
        self.viewModel = .init(source: source)
        super.init()
    }

    override func observe() {
        super.observe()

        viewModel.$loadingInitial
            .sink { [weak self] loading in
                guard let self, !loading else { return }
                self.hideLoadingView()
            }
            .store(in: &cancellables)

        viewModel.$entries
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if self.viewModel.error == nil {
                        self.updateDataSource()
                    }
                }
            }
            .store(in: &cancellables)

        viewModel.$error
            .sink { [weak self] error in
                guard let self else { return }
                // Search failures leave an empty result list, without an error overlay.
                // A failed next page keeps the results that have already loaded.
                self.errorView.hide(animated: false)
                if error != nil && self.viewModel.entries.isEmpty {
                    self.clearEntries()
                }
            }
            .store(in: &cancellables)

        viewModel.$shouldScrollToTop
            .sink { [weak self] shouldScroll in
                guard let self, shouldScroll else { return }
                self.scrollToTop()
                self.viewModel.shouldScrollToTop = false
            }
            .store(in: &cancellables)

        addObserver(forName: .init("refresh-content")) { [weak self] _ in
            guard let self else { return }
            self.viewModel.loadManga(
                searchText: self.searchText,
                filters: self.enabledFilters,
                force: true
            )
        }
    }
}

extension SourceSearchViewController {
    func onAppear() {
        viewModel.onAppear(searchText: searchText, filters: enabledFilters)
    }

    func scrollToTop(animated: Bool = true) {
        collectionView.setContentOffset(.init(x: 0, y: -view.safeAreaInsets.top), animated: animated)
    }

    @objc override func refresh(_ control: UIRefreshControl) {
        Task {
            viewModel.loadManga(searchText: searchText, filters: enabledFilters, force: true)
            await viewModel.waitForSearch()
            control.endRefreshing()
            scrollToTop() // it scrolls down slightly after refresh ends
        }
    }
}

// MARK: UICollectionViewDelegate
extension SourceSearchViewController {
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        let mangaCount = viewModel.entries.count
        let hasMore = viewModel.hasMore
        if viewModel.error == nil && mangaCount > 0 && indexPath.item >= max(0, mangaCount - SourcePrefetchPolicy.threshold(for: collectionView)) && hasMore {
            Task {
                await viewModel.loadMore(searchText: searchText, filters: enabledFilters)
            }
        }
    }
}

// MARK: UISearchBarDelegate
extension SourceSearchViewController {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        viewModel.loadManga(
            searchText: searchText,
            filters: enabledFilters,
            delay: true
        )
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        viewModel.loadManga(
            searchText: searchText,
            filters: enabledFilters,
            force: viewModel.error != nil
        )
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchText = ""
        viewModel.loadManga(
            searchText: searchText,
            filters: enabledFilters
        )
    }
}
