//
//  DownloadCache.swift
//  Aidoku
//
//  Created by Skitty on 5/13/22.
//

import Foundation

// cache of downloads directory contents on the filesystem
// TODO: should probably be reloaded every once in a while so we can recheck filesystem for user modifications
@MainActor
class DownloadCache {
    struct Directory: Sendable {
        var url: URL
        var subdirectories: [String: Directory] = [:]
    }

    private var rootDirectory = Directory(url: DownloadManager.directory)
    private var loaded = false
    private var touchedManga = Set<String>()
    private var scanGeneration = UUID()
    private var scan: Task<Directory, Never>?

    init() {
        let directory = DownloadManager.directory
        let generation = scanGeneration
        let work = Task.detached(priority: .utility) { Self.scanDirectory(directory) }
        scan = work
        Task { [weak self] in
            let snapshot = await work.value
            guard let self, scanGeneration == generation else { return }
            for (sourceKey, source) in snapshot.subdirectories {
                if rootDirectory.subdirectories[sourceKey] == nil {
                    rootDirectory.subdirectories[sourceKey] = Directory(url: source.url)
                }
                for (mangaKey, manga) in source.subdirectories where !touchedManga.contains(manga.url.path) {
                    rootDirectory.subdirectories[sourceKey]?.subdirectories[mangaKey] = manga
                }
            }
            loaded = true
            touchedManga.removeAll()
            scan = nil
        }
    }

    deinit { scan?.cancel() }

    private nonisolated static func scanManga(_ directory: URL) -> Directory {
        var result = Directory(url: directory)
        for chapter in directory.contents {
            if Task.isCancelled { break }
            guard !chapter.lastPathComponent.hasPrefix("."),
                  chapter.isDirectory || chapter.pathExtension.lowercased() == "cbz" else { continue }
            let key = chapter.isDirectory ? chapter.lastPathComponent : chapter.deletingPathExtension().lastPathComponent
            result.subdirectories[key] = Directory(url: chapter)
        }
        return result
    }

    private nonisolated static func scanDirectory(_ directory: URL) -> Directory {
        var result = Directory(url: directory)
        for source in directory.contents where source.isDirectory {
            if Task.isCancelled { break }
            var entry = Directory(url: source)
            for manga in source.contents where manga.isDirectory {
                if Task.isCancelled { break }
                entry.subdirectories[manga.lastPathComponent] = scanManga(manga)
            }
            result.subdirectories[source.lastPathComponent] = entry
        }
        return result
    }

    // Synchronous UI lookups never trigger a scan of the entire download tree.
    // Until background discovery finishes, inspect just the requested manga.
    private func loadIfNeeded(_ manga: MangaIdentifier) {
        let url = directory(for: manga)
        guard !loaded, !touchedManga.contains(url.path), isSafe(manga: manga) else { return }
        touchedManga.insert(url.path)
        let sourceKey = manga.sourceKey.directoryName
        if rootDirectory.subdirectories[sourceKey] == nil {
            rootDirectory.subdirectories[sourceKey] = Directory(url: directory(sourceKey: manga.sourceKey))
        }
        rootDirectory.subdirectories[sourceKey]?.subdirectories[manga.mangaKey.directoryName] = Self.scanManga(url)
    }

    // add chapter to directory cache
    func add(chapter: ChapterIdentifier) {
        guard isSafe(chapter: chapter) else { return }
        loadIfNeeded(chapter.mangaIdentifier)
        if !loaded { touchedManga.insert(directory(for: chapter.mangaIdentifier).path) }
        let sourceDirectory = rootDirectory.subdirectories[chapter.sourceKey.directoryName]
        let sourceDirectoryURL = DownloadManager.directory.appendingSafePathComponent(chapter.sourceKey)
        if sourceDirectory == nil {
            rootDirectory.subdirectories[chapter.sourceKey.directoryName] = Directory(
                url: sourceDirectoryURL
            )
        }
        if sourceDirectory?.subdirectories[chapter.mangaKey.directoryName] == nil {
            rootDirectory
                .subdirectories[chapter.sourceKey.directoryName]?
                .subdirectories[chapter.mangaKey.directoryName] = Directory(
                    url: sourceDirectoryURL.appendingSafePathComponent(chapter.mangaKey)
                )
        }
        if sourceDirectory?.subdirectories[chapter.mangaKey.directoryName]?.subdirectories[chapter.chapterKey.directoryName] == nil {
            rootDirectory
                .subdirectories[chapter.sourceKey.directoryName]?
                .subdirectories[chapter.mangaKey.directoryName]?
                .subdirectories[chapter.chapterKey.directoryName] = Directory(
                    url: directory(for: chapter)
                )
        }
    }

    func remove(manga: MangaIdentifier) {
        if !loaded { touchedManga.insert(directory(for: manga).path) }
        rootDirectory.subdirectories[manga.sourceKey.directoryName]?
            .subdirectories[manga.mangaKey.directoryName] = nil
    }

    func remove(chapter: ChapterIdentifier) {
        loadIfNeeded(chapter.mangaIdentifier)
        if !loaded { touchedManga.insert(directory(for: chapter.mangaIdentifier).path) }
        rootDirectory.subdirectories[chapter.sourceKey.directoryName]?
            .subdirectories[chapter.mangaKey.directoryName]?
            .subdirectories[chapter.chapterKey.directoryName] = nil
    }

    func removeAll() {
        scanGeneration = UUID()
        scan?.cancel(); scan = nil
        rootDirectory = Directory(url: DownloadManager.directory)
        touchedManga.removeAll()
        loaded = true
        DownloadManager.directory.removeItem()
    }
}

extension DownloadCache {
    // check if a chapter has a download directory
    func isChapterDownloaded(identifier: ChapterIdentifier) -> Bool {
        guard Self.hasValidDownloadNames([identifier.sourceKey, identifier.mangaKey, identifier.chapterKey]) else { return false }
        loadIfNeeded(identifier.mangaIdentifier)
        guard
            let sourceDirectory = rootDirectory.subdirectories[identifier.sourceKey.directoryName],
            let mangaDirectory = sourceDirectory.subdirectories[identifier.mangaKey.directoryName]
        else {
            return false
        }
        return mangaDirectory.subdirectories[identifier.chapterKey.directoryName] != nil
    }

    // check if any chapter subdirectories exist
    func hasDownloadedChapter(from identifier: MangaIdentifier) -> Bool {
        guard Self.hasValidDownloadNames([identifier.sourceKey, identifier.mangaKey]) else { return false }
        loadIfNeeded(identifier)
        guard
            let sourceDirectory = rootDirectory.subdirectories[identifier.sourceKey.directoryName],
            let mangaDirectory = sourceDirectory.subdirectories[identifier.mangaKey.directoryName]
        else {
            return false
        }
        return mangaDirectory.subdirectories.contains { !$0.value.url.lastPathComponent.hasPrefix(".tmp") }
    }
}

// MARK: Directory Provider
extension DownloadCache {
    /// Keep the existing sanitized names, but never accept navigation names or
    /// filesystem aliases that redirect a download outside its own hierarchy.
    nonisolated static func isSafeDownloadPath(components: [String], root: URL = DownloadManager.directory) -> Bool {
        guard root.isFileURL, !components.isEmpty else { return false }
        let expectedRoot = root.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent).standardizedFileURL
        var directory = root.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path == expectedRoot.path else { return false }
        for rawComponent in components {
            let component = rawComponent.directoryName
            guard !component.isEmpty, component != ".", component != ".." else { return false }
            let next = directory.appendingPathComponent(component).standardizedFileURL
            guard next.resolvingSymlinksInPath().path == next.path else { return false }
            directory = next
        }
        return true
    }

    nonisolated static func hasValidDownloadNames(_ components: [String]) -> Bool {
        components.allSatisfy {
            let name = $0.directoryName
            return !name.isEmpty && name != "." && name != ".."
        }
    }

    nonisolated func isSafe(manga: MangaIdentifier) -> Bool {
        Self.isSafeDownloadPath(components: [manga.sourceKey, manga.mangaKey])
    }

    nonisolated func isSafe(chapter: ChapterIdentifier) -> Bool {
        Self.isSafeChapterPath(source: chapter.sourceKey, manga: chapter.mangaKey, chapter: chapter.chapterKey)
    }

    nonisolated static func isSafeChapterPath(source: String, manga: String, chapter: String,
                                             root: URL = DownloadManager.directory) -> Bool {
        guard root.isFileURL else { return false }
        let expectedRoot = root.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent).standardizedFileURL
        var directory = root.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path == expectedRoot.path else { return false }
        // Resolve each ancestor once, then check distinct final/staging targets.
        for rawComponent in [source, manga] {
            let component = rawComponent.directoryName
            guard !component.isEmpty, component != ".", component != ".." else { return false }
            let next = directory.appendingPathComponent(component).standardizedFileURL
            guard next.resolvingSymlinksInPath().path == next.path else { return false }
            directory = next
        }
        let name = chapter.directoryName
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return [name, name + ".cbz", Self.tmpDirectoryPrefix + name, Self.tmpDirectoryPrefix + name + ".cbz"]
            .allSatisfy {
                let target = directory.appendingPathComponent($0).standardizedFileURL
                return target.resolvingSymlinksInPath().path == target.path
            }
    }

    nonisolated func directory(sourceKey: String) -> URL {
        DownloadManager.directory
            .appendingSafePathComponent(sourceKey)
    }

    nonisolated func directory(for manga: MangaIdentifier) -> URL {
        DownloadManager.directory
            .appendingSafePathComponent(manga.sourceKey)
            .appendingSafePathComponent(manga.mangaKey)
    }

    nonisolated func directory(for chapter: ChapterIdentifier) -> URL {
        DownloadManager.directory
            .appendingSafePathComponent(chapter.sourceKey)
            .appendingSafePathComponent(chapter.mangaKey)
            .appendingSafePathComponent(chapter.chapterKey)
    }

    /// Prefix of the directory a chapter is downloaded into before it is promoted to a chapter.
    nonisolated static let tmpDirectoryPrefix = ".tmp_"

    nonisolated func tmpDirectory(for chapter: ChapterIdentifier) -> URL {
        DownloadManager.directory
            .appendingSafePathComponent(chapter.sourceKey)
            .appendingSafePathComponent(chapter.mangaKey)
            .appendingSafePathComponent("\(Self.tmpDirectoryPrefix)\(chapter.chapterKey)")
    }

    // marker file for failed downloads, which is contained inside a .tmp directory
    nonisolated static let failureMarkerName = ".failed"

    nonisolated func failureMarker(inTmpDirectory directory: URL) -> URL {
        directory.appendingPathComponent(Self.failureMarkerName)
    }

    /// Whether a staging directory holds a download that failed rather than one still running.
    nonisolated func hasFailureMarker(inTmpDirectory directory: URL) -> Bool {
        failureMarker(inTmpDirectory: directory).exists
    }
}
