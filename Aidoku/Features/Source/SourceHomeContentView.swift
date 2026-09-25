//
//  SourceHomeContentView.swift
//  Aidoku
//
//  Created by Skitty on 4/28/25.
//

import AidokuRunner
import SwiftUI

struct SourceHomeContentView: View {
    let source: AidokuRunner.Source

    @Binding var listings: [AidokuRunner.Listing]
    @Binding var headerListingSelection: Int // used only for listing header

    @State private var home: Home?
    @StateObject private var listingModel: SourceListingViewModel

    @State private var hasLoaded = false
    @State private var loading = true
    @State private var homeFullyLoaded = false
    @State private var homeGeneration = 0
    @State private var listingSelection = 0
    @State private var error: Error?

    @State private var loadTask: Task<(), Never>?
    @State private var loadListingTask: Task<(), Never>?

    @StateObject private var path: NavigationCoordinator

    private var currentListing: AidokuRunner.Listing? {
        listing(for: listingSelection)
    }

    private func listing(for selection: Int) -> AidokuRunner.Listing? {
        let listingIndex = selection - (source.features.providesHome ? 1 : 0)
        return listings[safe: listingIndex]
    }

    init(
        source: AidokuRunner.Source,
        holdingViewController: UIViewController,
        listings: Binding<[AidokuRunner.Listing]>,
        headerListingSelection: Binding<Int>
    ) {
        self.source = source
        self._listingModel = StateObject(wrappedValue: SourceListingViewModel(
            getPage: { try await source.getMangaList(listing: $0, page: $1) },
            getHome: { try await source.getListingHome(listing: $0) }
        ))
        self._listings = listings
        self._headerListingSelection = headerListingSelection
        self._path = StateObject(wrappedValue: NavigationCoordinator(rootViewController: holdingViewController))
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack {}.id(0) // indicator to scroll to the top

                Group {
                    if loading || listingModel.loadingInitial {
                        // loading skeleton
                        loadingView().transition(.opacity)
                    } else if let home, listingSelection == 0 {
                        // home page
                        homeView(for: home, partial: !homeFullyLoaded)
                    } else if listingSelection > 0 || !source.features.providesHome, let listing = currentListing {
                        // listing page - check if source provides custom Home-like layout
                        if let listingHome = listingModel.home {
                            homeView(for: listingHome, partial: false)
                                .transition(.opacity)
                        } else {
                            // Display listing with listing.kind
                            Group {
                                switch listing.kind {
                                    case .default:
                                        HomeGridView(source: source, entries: listingModel.entries, bookmarkedItems: $listingModel.bookmarkedItems) {
                                            await listingModel.loadMore()
                                        }
                                    case .list:
                                        HomeListView(
                                            source: source,
                                            component: .init(title: nil, value: .mangaList(entries: listingModel.entries.map { $0.intoLink() })),
                                            bookmarkedItems: $listingModel.bookmarkedItems
                                        ) {
                                            await listingModel.loadMore()
                                        }
                                        .id(listingSelection) // Force recreation on listing change
                                        .padding(.bottom)
                                }
                            }
                            .transition(.opacity)
                        }
                    } else {
                        loadingView().frame(height: 200).hidden()
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity((error ?? listingModel.error) != nil ? 0 : 1)
            }
            .overlay {
                if let error = error ?? listingModel.error {
                    ErrorView(
                        error: error,
                        restart: { try await source.restart() },
                        retry: {
                            if listingModel.error != nil {
                                await listingModel.loadMore()
                            } else {
                                await reload()
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .padding()
                }
            }
            .refreshable {
                // nesting task prevents it from being cancelled
                let task = Task {
                    try? await Task.sleep(nanoseconds: 100_000_000) // delay to fix animation
                    await reload()
                }
                await task.value
            }
            // update listingSelection when header selection changes;
            // a separate variable is used in order to perform the rest of the changes along with listingSelection
            // immediately rather than having a slight delay
            .onChange(of: headerListingSelection) { value in
                loadListingTask?.cancel()
                listingModel.cancel()
                withAnimation(.easeOut(duration: 0.2)) {
                    reader.scrollTo(0)
                    listingSelection = value
                    error = nil
                }
                loadListingTask = Task {
                    if value != 0 || !source.features.providesHome {
                        await loadListing()
                    } else if home == nil {
                        loading = true
                        homeFullyLoaded = false
                        await loadHome()
                    } else {
                        loading = false
                    }
                }
            }
        }
        .onChange(of: listings) { value in
            // reset listing selection to the first if the selected one disappears
            let maxListings = value.count - (source.features.providesHome ? 0 : 1)
            if listingSelection > maxListings {
                headerListingSelection = 0
            } else if !source.features.providesHome || (source.features.providesHome && listingSelection > 0) {
                // Initial discovery or a changed listing needs a load. A refresh already
                // loading this listing must not issue the same first-page request twice.
                if listingModel.currentListing != currentListing {
                    Task { await loadListing() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("refresh-content"))) { _ in
            loadTask?.cancel()
            loadTask = Task {
                guard !Task.isCancelled else { return }
                await reload()
                // reload home page even if we're not on it
                if source.features.providesHome && listingSelection != 0 {
                    await loadHome()
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await reload(initial: true)
        }
        .environmentObject(path)
    }

    @ViewBuilder
    private func loadingView() -> some View {
        Group {
            if listingSelection == 0 && source.features.providesHome {
                SourceHomeSkeletonView(source: source)
            } else if let listing = currentListing {
                switch listing.kind {
                    case .default:
                        HomeGridView.placeholder
                    case .list:
                        PlaceholderMangaHomeList(showTitle: false)
                }
            }
        }
    }

    func homeView(for home: Home, partial: Bool) -> some View {
        VStack(spacing: 24) {
            ForEach(home.components.indices, id: \.self) { offset in
                let component = home.components[offset]
                switch component.value {
                    case .imageScroller:
                        HomeImageScrollerView(source: source, component: component, partial: partial)
                    case .bigScroller:
                        HomeBigScrollerView(source: source, component: component, partial: partial)
                    case .scroller:
                        HomeScrollerView(source: source, component: component, partial: partial)
                    case .mangaList:
                        HomeListView(source: source, component: component, partial: partial)
                            .id("listing-\(offset)") // Force recreation for listing components
                    case .mangaChapterList:
                        HomeChapterListView(source: source, component: component, partial: partial)
                    case .filters:
                        HomeFiltersView(source: source, component: component, partial: partial)
                    case .links:
                        HomeLinksView(source: source, component: component, partial: partial)
                }
            }
            .transition(.opacity)
        }
        .padding(.bottom)
    }

    func reload(initial: Bool = false) async {
        loadListingTask?.cancel()
        listingModel.cancel()
        if error != nil {
            withAnimation {
                loading = true
                error = nil
            }
        }
        // only load listings when actually reloading
        // they're loaded in ListingsHeaderView initially
        if !initial {
            // don't fail the entire home screen if listings fail to load
            if let newListings = try? await source.getListings() {
                listings = newListings
            }
            guard !Task.isCancelled else { return }
        }
        homeFullyLoaded = false
        if source.features.providesHome && listingSelection == 0 {
            await loadHome()
        } else {
            await loadListing()
        }
    }

    func loadHome() async {
        homeGeneration += 1
        let requestGeneration = homeGeneration
        let source = source
        let publisher = source.partialHomePublisher
        do {
            let home = try await SourceHomeSubscription.load(publisher: publisher, receive: { @Sendable partialHome in
                Task { @MainActor in
                    guard homeGeneration == requestGeneration else { return }
                    withAnimation {
                        self.home = partialHome
                        if headerListingSelection == 0 { loading = false }
                    }
                }
            }, operation: { try await source.getHome() })
            guard homeGeneration == requestGeneration else { return }
            try Task.checkCancellation()
            withAnimation {
                self.home = home
            }

            // update stored component types for skeleton loading
            let storedComponentsKey = "\(source.key).homeComponents"
            let storedComponents = UserDefaults.standard.array(forKey: storedComponentsKey)
            let componentCount = storedComponents.flatMap { $0.count / 2 } ?? 0
            if componentCount != home.components.count {
                let result = home.components.flatMap {
                    switch $0.value {
                        case let .mangaList(_, pageSize, entries, _):
                            return [3, min(pageSize ?? .max, entries.count)]
                        case let .mangaChapterList(pageSize, entries, _):
                            return [4, min(pageSize ?? .max, entries.count)]
                        default:
                            return [$0.value.intValue, 0]
                    }
                }
                UserDefaults.standard.set(result, forKey: storedComponentsKey)
            }
        } catch {
            guard homeGeneration == requestGeneration else { return }
            if !Task.isCancelled, headerListingSelection == 0 {
                self.home = nil
                withAnimation { self.error = error }
            }
        }
        guard homeGeneration == requestGeneration else { return }
        guard !Task.isCancelled, homeGeneration == requestGeneration else { return }

        withAnimation {
            if headerListingSelection == 0 {
                loading = false
            }
            homeFullyLoaded = true
        }
    }

    func loadListing() async {
        guard !Task.isCancelled, let listing = currentListing else { return }
        loading = false
        await listingModel.reload(listing: listing)
    }
}
