//
//  MangaListViewController.swift
//  Aidoku
//
//  Created by Skitty on 11/19/25.
//

import AidokuRunner
import UIKit

class MangaListViewController: MangaCollectionViewController {
    let source: AidokuRunner.Source

    var getEntries: ((Int) async throws -> AidokuRunner.MangaPageResult)?

    private var loaded = false
    private lazy var pageModel = SourceListingViewModel(getPage: { [weak self] _, page in
        guard let getEntries = self?.getEntries else {
            return .init(entries: [], hasNextPage: false)
        }
        return try await getEntries(page)
    })

    override var entries: [AidokuRunner.Manga] {
        get { pageModel.entries }
        set { pageModel.entries = newValue }
    }

    override var bookmarkedItems: Set<String> {
        get { pageModel.bookmarkedItems }
        set { pageModel.bookmarkedItems = newValue }
    }

    init(
        source: AidokuRunner.Source,
        title: String = "",
        listingKind: ListingKind = .default
    ) {
        self.source = source
        super.init()

        self.usesListLayout = listingKind == .list
        self.title = title
    }

    override func configure() {
        super.configure()
        navigationItem.largeTitleDisplayMode = .never
        errorView.onRetry = { [weak self] in
            await self?.pageModel.loadMore()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !loaded else { return }
        loaded = true
        Task {
            await pageModel.reload(listing: .init(id: "", name: title ?? ""))
            hideLoadingView()
        }
    }

    override func observe() {
        super.observe()
        pageModel.$entries.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDataSource() }
        }.store(in: &cancellables)
        pageModel.$error.sink { [weak self] error in
            guard let self else { return }
            if let error {
                errorView.setError(error)
                errorView.show()
            } else {
                errorView.hide()
            }
        }.store(in: &cancellables)
    }

    @objc override func refresh(_ control: UIRefreshControl) {
        Task {
            await pageModel.reload(listing: .init(id: "", name: title ?? ""))
            control.endRefreshing()
        }
    }
}

// MARK: UICollectionViewDelegate
extension MangaListViewController {
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        if !entries.isEmpty && indexPath.item >= max(0, entries.count - SourcePrefetchPolicy.threshold(for: collectionView)) && pageModel.hasMore {
            Task {
                await pageModel.loadMore()
            }
        }
    }
}
