//
//  FilterGroupCreateView.swift
//  Aidoku
//
//  Created by Skitty on 2/27/26.
//

import SwiftUI

struct FilterGroupCreateView: View {
    // the filter group we're editing, if we're not creating a new one
    var editingGroupTitle: String?

    @State private var title: String = ""
    @State private var filters: [LibraryFilter] = []
    @State private var isValid = false
    @State private var isSaving = false
    @State private var saveError: String?

    @State private var categories: [String] = []
    @State private var sourceKeys: [String] = []

    @State private var allCategoryAndGroupTitles: [String] = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlatformNavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Text(NSLocalizedString("NAME"))
                        TextField(editingGroupTitle ?? NSLocalizedString("NAME"), text: $title)
                    }
                }

                Section(NSLocalizedString("FILTERS")) {
                    ForEach(LibraryFilter.FilterMethod.allCases, id: \.self) { method in
                        if method.isAvailable {
                            let state = filterState(for: method)
                            Button {
                                toggleFilter(method: method)
                            } label: {
                                HStack {
                                    Image(systemName: method.systemImageName)
                                        .frame(minWidth: 30)
                                        .foregroundStyle(.tint)
                                    Text(method.title)
                                    Spacer()
                                    switch state {
                                        case .included: Image(systemName: "checkmark").foregroundStyle(.tint)
                                        case .excluded: Image(systemName: "xmark").foregroundStyle(.tint)
                                        case .none: EmptyView()
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }

                    DisclosureGroup {
                        ForEach(MangaContentRating.allCases, id: \.self) { rating in
                            let state = filterState(for: .contentRating, value: rating.stringValue)
                            Button {
                                toggleFilter(method: .contentRating, value: rating.stringValue)
                            } label: {
                                HStack {
                                    Text(rating.title)
                                    Spacer()
                                    switch state {
                                        case .included: Image(systemName: "checkmark").foregroundStyle(.tint)
                                        case .excluded: Image(systemName: "xmark").foregroundStyle(.tint)
                                        case .none: EmptyView()
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } label: {
                        HStack {
                            Image(systemName: LibraryFilter.FilterMethod.contentRating.systemImageName)
                                .frame(minWidth: 30)
                                .foregroundStyle(.tint)
                            Text(LibraryFilter.FilterMethod.contentRating.title)
                            Spacer()
                        }
                    }

                    if !sourceKeys.isEmpty {
                        DisclosureGroup {
                            ForEach(sourceKeys, id: \.self) { key in
                                let state = filterState(for: .source, value: key)
                                Button {
                                    toggleFilter(method: .source, value: key)
                                } label: {
                                    HStack {
                                        Text(SourceManager.shared.store.source(for: key)?.name ?? key)
                                        Spacer()
                                        switch state {
                                            case .included: Image(systemName: "checkmark").foregroundStyle(.tint)
                                            case .excluded: Image(systemName: "xmark").foregroundStyle(.tint)
                                            case .none: EmptyView()
                                        }
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        } label: {
                            HStack {
                                Image(systemName: LibraryFilter.FilterMethod.source.systemImageName)
                                    .frame(minWidth: 30)
                                    .foregroundStyle(.tint)
                                Text(LibraryFilter.FilterMethod.source.title)
                                Spacer()
                            }
                        }
                    }

                    if !categories.isEmpty {
                        DisclosureGroup {
                            ForEach(categories, id: \.self) { category in
                                let state = filterState(for: .category, value: category)
                                Button {
                                    toggleFilter(method: .category, value: category)
                                } label: {
                                    HStack {
                                        Text(category)
                                        Spacer()
                                        switch state {
                                            case .included: Image(systemName: "checkmark").foregroundStyle(.tint)
                                            case .excluded: Image(systemName: "xmark").foregroundStyle(.tint)
                                            case .none: EmptyView()
                                        }
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        } label: {
                            HStack {
                                Image(systemName: LibraryFilter.FilterMethod.category.systemImageName)
                                    .frame(minWidth: 30)
                                    .foregroundStyle(.tint)
                                Text(LibraryFilter.FilterMethod.category.title)
                                Spacer()
                            }
                        }
                    }
                }

                Section {
                    Button(NSLocalizedString("CLEAR_FILTERS")) {
                        filters = []
                    }
                    .disabled(filters.isEmpty)
                }
            }
            .scrollDismissesKeyboardImmediately()
            .navigationTitle(editingGroupTitle != nil ? NSLocalizedString("EDIT_FILTER_GROUP") : NSLocalizedString("CREATE_FILTER_GROUP"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton {
                        guard !isSaving else { return }
                        isSaving = true
                        Task {
                            if await commit() { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .alert(NSLocalizedString("UNKNOWN_ERROR"), isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button(NSLocalizedString("OK"), role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onChange(of: title) { _ in
                checkValidity()
            }
            .onChange(of: filters) { _ in
                if filters.isEmpty {
                    isValid = false
                } else if !isValid {
                    checkValidity()
                }
            }
            .task {
                await loadData()
            }
        }
    }
}

extension FilterGroupCreateView {
    func loadData() async {
        (
            categories,
            allCategoryAndGroupTitles,
            sourceKeys,
            filters
        ) = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            let categories = CoreDataManager.shared.getCategoryTitles(context: context)
            let allCategoryAndGroupTitles = CoreDataManager.shared.getCategoryTitles(excludeFilterGroups: false, context: context)

            let request = LibraryMangaObject.fetchRequest()
            request.predicate = NSPredicate(format: "manga != nil")
            let libraryObjects = (try? context.fetch(request)) ?? []

            var sourceKeys: Set<String> = []
            for object in libraryObjects {
                guard let manga = object.manga else { continue }
                sourceKeys.insert(manga.sourceId)
            }

            var filters: [LibraryFilter] = []
            if let editingGroupTitle {
                let request = CategoryObject.fetchRequest()
                request.predicate = NSPredicate(format: "title == %@", editingGroupTitle)
                request.fetchLimit = 1
                if
                    let category = (try? context.fetch(request))?.first,
                    let data = category.data as? Data,
                    let filterData = try? JSONDecoder().decode([LibraryFilter].self, from: data)
                {
                    filters = filterData
                }
            }

            return (categories, allCategoryAndGroupTitles, sourceKeys.sorted(), filters)
        }

        // if we're editing a group, it's okay if it has the same title when checking validity
        if let editingGroupTitle, let index = allCategoryAndGroupTitles.firstIndex(of: editingGroupTitle) {
            allCategoryAndGroupTitles.remove(at: index)
        }

        // add any existing filtered items if they're missing from the data (e.g. removed source/category)
        for filter in filters {
            guard let value = filter.value else { continue }
            switch filter.type {
                case .source:
                    if !sourceKeys.contains(value) {
                        sourceKeys.append(value)
                    }
                case .category:
                    if !categories.contains(value) {
                        categories.append(value)
                    }
                default: break
            }
        }
    }

    func checkValidity() {
        var title = title.trim()
        if title.isEmpty {
            title = editingGroupTitle ?? ""
        }
        guard
            !filters.isEmpty,
            !title.isEmpty,
            title.lowercased() != "none",
            !allCategoryAndGroupTitles.contains(title)
        else {
            isValid = false
            return
        }
        isValid = true
    }
}

extension FilterGroupCreateView {
    func commit() async -> Bool {
        guard isValid else { return false }
        guard let data = try? JSONEncoder().encode(filters) else {
            LogManager.logger.error("Failed to encode filters data")
            saveError = NSLocalizedString("UNKNOWN_ERROR")
            return false
        }
        let title = title.trim()
        if let editingGroupTitle {
            do {
                try await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
                    try CoreDataManager.shared.updateFilterGroupAndSave(
                        title: editingGroupTitle, newTitle: title, data: data, context: context
                    )
                }
            } catch {
                LogManager.logger.error("Failed to edit filter group: \(error)")
                saveError = error.localizedDescription
                return false
            }
        } else {
            do {
                try await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
                    let category = try CoreDataManager.shared.createCategory(title: title, group: true, context: context)
                    category.data = data as NSObject
                    do { try context.save() } catch { context.rollback(); throw error }
                }
            } catch {
                LogManager.logger.error("Failed to create filter group: \(error)")
                saveError = error.localizedDescription
                return false
            }
        }
        NotificationCenter.default.post(name: .updateCategories, object: nil)
        return true
    }
}

extension FilterGroupCreateView {
    func toggleFilter(method: LibraryFilter.FilterMethod, value: String? = nil) {
        let filterIndex = filters.firstIndex(where: { $0.type == method && $0.value == value })
        if let filterIndex {
            if filters[filterIndex].exclude {
                filters.remove(at: filterIndex)
            } else {
                filters[filterIndex].exclude = true
            }
        } else {
            filters.append(.init(type: method, value: value, exclude: false))
        }
    }

    enum FilterState {
        case none
        case included
        case excluded
    }

    func filterState(for method: LibraryFilter.FilterMethod, value: String? = nil) -> FilterState {
        if let filter = filters.first(where: { $0.type == method && $0.value == value }) {
            filter.exclude ? .excluded : .included
        } else {
            .none
        }
    }
}

#Preview {
    FilterGroupCreateView()
}
