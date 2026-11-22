//
//  MangaUpdatesView.swift
//  Aidoku (iOS)
//
//  Created by axiel7 on 09/02/2024.
//

import AidokuRunner
import CoreData
import SwiftUI

struct MangaUpdatesView: View {
    struct UpdateSection: Hashable {
        let day: Int
        var items: [Item]
    }
    struct Item: Hashable {
        let mangaId: MangaIdentifier
        var updates: [UpdateInfo]
    }
    struct UpdateInfo: Identifiable, Hashable {
        var id: ChapterIdentifier { chapterIdentifier }
        let chapterIdentifier: ChapterIdentifier
        let date: Date
        let manga: AidokuRunner.Manga
        let chapter: Chapter?
        var viewed: Bool
    }

    private let limit = 25

    @State private var entries: [UpdateSection] = []
    @State private var offset = 0
    @State private var loadingMore = false
    @State private var reachedEnd = false
    @State private var hasNoUpdates = false
    @State private var loadingTask: Task<(), Never>?
    @StateObject private var operations = MangaUpdatesOperationQueue()

    @EnvironmentObject private var path: NavigationCoordinator

    var body: some View {
        Group {
            List {
                listItemsWithSections

                if !reachedEnd {
                    loadingView
                        .onAppear {
                            if !loadingMore {
                                reachedEnd = true
                                loadingMore = true
                                loadingTask = Task {
                                    await operations.run { await loadNewEntries() }
                                }
                            }
                        }
                } else if loadingMore {
                    loadingView
                }
            }
            .listStyle(.plain)
            .overlay {
                if hasNoUpdates {
                    VStack(alignment: .center) {
                        Spacer()
                        Text(NSLocalizedString("NO_UPDATES"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("MANGA_UPDATES"))
        .onReceive(NotificationCenter.default.publisher(for: .mangaUpdatesViewed).receive(on: DispatchQueue.main)) { notification in
            guard let objects = notification.object as? [MangaUpdateItem] else { return }

            let viewed = Set(objects.lazy.map(\.chapterId))
            Task { await operations.markViewed(viewed, in: $entries) }
        }
    }

    var listItemsWithSections: some View {
        ForEach(entries, id: \.day) { entry in
            Section {
                let items = entry.items
                ForEach(items, id: \.mangaId) { item in
                    let updates = item.updates
                    if let update = updates.first {
                        NavigationLink(
                            destination: MangaView(manga: update.manga, path: path)
                                .onAppear {
                                    setOpened(manga: update.manga)
                                }
                        ) {
                            MangaUpdateItemView(updates: updates)
                        }
                        .offsetListSeparator()
                        .id(item.mangaId)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                removeUpdateItem(item: item, day: entry.day)
                            } label: {
                                Label(NSLocalizedString("DELETE"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(Date.makeRelativeDate(days: entry.day))
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .listRowSeparator(.hidden)
        }
    }

    var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
                .id(UUID()) // fixes progress view being invisible
            Spacer()
        }
        .listRowSeparator(.hidden)
    }
}

extension MangaUpdatesView {
    nonisolated static func loadPage(limit: Int, offset: Int, context: NSManagedObjectContext) -> (updates: [UpdateInfo], fetched: Int) {
        let rows = CoreDataManager.shared.getRecentMangaUpdates(limit: limit, offset: offset, context: context)
        var mangaById: [MangaIdentifier: AidokuRunner.Manga] = [:]
        for (mangaId, group) in Dictionary(grouping: rows, by: { $0.identifier.mangaIdentifier }) {
            // Restored rows can lack a chapter relationship. Resolve those titles by their stored keys.
            let linked = group.first?.chapter?.manga
            let object = linked?.identifier == mangaId ? linked : CoreDataManager.shared.getManga(mangaId: mangaId, context: context)
            mangaById[mangaId] = object?.toNewManga()
        }
        let updates: [UpdateInfo] = rows.compactMap { row in
            let id = row.identifier
            guard let manga = mangaById[id.mangaIdentifier] else { return nil }
            return UpdateInfo(
                chapterIdentifier: id,
                date: row.date ?? Date(),
                manga: manga,
                chapter: row.chapter?.toChapter(),
                viewed: row.viewed
            )
        }
        return (updates, rows.count)
    }

    private func loadNewEntries() async {
        let (newUpdates, fetchedCount) = await CoreDataManager.shared.container.performBackgroundTask { [offset] context in
            Self.loadPage(limit: limit, offset: offset, context: context)
        }
        guard !Task.isCancelled else { return }
        offset += fetchedCount
        guard !newUpdates.isEmpty else {
            reachedEnd = fetchedCount < limit
            loadingMore = false
            if !reachedEnd {
                await loadNewEntries()
            } else {
                withAnimation { hasNoUpdates = entries.isEmpty }
            }
            return
        }

        let newUpdatesGrouped = Dictionary(grouping: newUpdates, by: \.manga.identifier)
        var updatesDict: [Int: [MangaIdentifier: [UpdateInfo]]] = entries
            .reduce(into: [:]) {
                $0[$1.day] = $1.items.reduce(into: [:]) {
                    $0[$1.mangaId] = $1.updates
                }
            }
        for obj in newUpdatesGrouped {
            for info in obj.value.sorted(by: { $0.date < $1.date }) {
                let day = Calendar.autoupdatingCurrent.dateComponents(
                    Set([Calendar.Component.day]),
                    from: info.date,
                    to: Date.endOfDay()
                ).day ?? 0

                var updatesOfTheDay = updatesDict[day] ?? [:]
                var newValue = updatesOfTheDay[obj.key] ?? []
                newValue.append(info)
                updatesOfTheDay[obj.key] = newValue
                updatesDict[day] = updatesOfTheDay
            }
        }
        let newEntries: [UpdateSection] = updatesDict
            .map {
                .init(
                    day: $0.key,
                    items: $0.value
                        .map { .init(mangaId: $0.key, updates: $0.value) }
                        .sorted { ($0.updates.first?.date ?? Date()) > ($1.updates.first?.date ?? Date()) }
                )
            }
            .sorted { $0.day < $1.day }

        guard !Task.isCancelled else { return }

        reachedEnd = fetchedCount < limit

        withAnimation {
            entries = newEntries
            loadingMore = false
            hasNoUpdates = newEntries.isEmpty
        }
    }

    private func setOpened(manga: AidokuRunner.Manga) {
        if !AppSettings.general.incognitoMode.get() {
            Task {
                await CoreDataManager.shared.setOpened(mangaId: manga.identifier)
                NotificationCenter.default.post(name: .updateLibrary, object: nil)
            }
        }
    }

    private func removeUpdateItem(item: Item, day: Int) {
        let updates = item.updates.map {
            $0.chapterIdentifier
        }

        var newEntries = entries
        if let sectionIndex = newEntries.firstIndex(where: { $0.day == day }) {
            var section = newEntries[sectionIndex]
            section.items.removeAll(where: { $0.mangaId == item.mangaId })
            if section.items.isEmpty {
                newEntries.remove(at: sectionIndex)
            } else {
                newEntries[sectionIndex] = section
            }
        }

        withAnimation {
            entries = newEntries
            if newEntries.isEmpty { hasNoUpdates = true }
        }

        Task {
            await operations.run {
                let removed = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.removeMangaUpdates(
                        updates: updates,
                        context: context
                    )
                    do {
                        try context.save()
                        return true
                    } catch {
                        context.rollback()
                        return false
                    }
                }
                if removed {
                    offset = max(0, offset - updates.count)
                } else {
                    entries = []
                    offset = 0
                    reachedEnd = false
                    hasNoUpdates = false
                    loadingMore = true
                    await loadNewEntries()
                }
            }
        }
    }
}

/// Serializes pagination and offset-changing mutations across their whole I/O span.
@MainActor
final class MangaUpdatesOperationQueue: ObservableObject {
    private var tail: Task<Void, Never>?
    private var tailID = UUID()

    func markViewed(_ ids: Set<ChapterIdentifier>, in entries: Binding<[MangaUpdatesView.UpdateSection]>) async {
        // Apply post-save notifications after any page that has already read older values.
        await run {
            var sections = entries.wrappedValue
            var changed = false
            for section in sections.indices {
                for item in sections[section].items.indices {
                    for index in sections[section].items[item].updates.indices {
                        let update = sections[section].items[item].updates[index]
                        if !update.viewed && ids.contains(update.id) {
                            sections[section].items[item].updates[index].viewed = true
                            changed = true
                        }
                    }
                }
            }
            if changed { entries.wrappedValue = sections }
        }
    }

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let predecessor = tail
        let issued = UUID()
        tailID = issued
        let task = Task {
            await predecessor?.value
            await operation()
        }
        tail = task
        await task.value
        if tailID == issued { tail = nil }
    }
}
