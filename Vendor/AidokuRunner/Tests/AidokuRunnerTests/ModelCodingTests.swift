//
//  ModelCodingTests.swift
//  AidokuRunnerTests
//
//  Created by Skitty on 8/13/23.
//

@testable import AidokuRunner
import Testing
import Foundation

struct ModelCodingTests {
    @Test func testMangaCoding() throws {
        let manga = Manga(
            sourceKey: "",
            key: "1",
            title: "Manga 1",
            cover: nil,
            artists: nil,
            authors: ["Author"],
            description: "Description",
            url: nil,
            tags: ["Tag"],
            status: .ongoing,
            contentRating: .safe,
            viewer: .webtoon,
            updateStrategy: .always,
            nextUpdateTime: nil,
            chapters: nil
        )
        let data = try PostcardEncoder().encode(manga)
        let decodedManga = try PostcardDecoder().decode(Manga.self, from: data)

        #expect(manga.key == decodedManga.key)
        #expect(manga.title == decodedManga.title)
        #expect(manga.cover == decodedManga.cover)
        #expect(manga.artists == decodedManga.artists)
        #expect(manga.authors == decodedManga.authors)
        #expect(manga.description == decodedManga.description)
        #expect(manga.url == decodedManga.url)
        #expect(manga.tags == decodedManga.tags)
        #expect(manga.status == decodedManga.status)
        #expect(manga.contentRating == decodedManga.contentRating)
        #expect(manga.viewer == decodedManga.viewer)
        #expect(manga.updateStrategy == decodedManga.updateStrategy)
        #expect(manga.nextUpdateTime == decodedManga.nextUpdateTime)
        #expect(manga.chapters?.count == decodedManga.chapters?.count)
    }
}

struct PostcardBoundaryTests {
    @Test func overlongVarIntThrows() {
        #expect(throws: (any Error).self) { try PostcardDecoder().decode(UInt16.self, from: Data([255,255,127])) }
    }

    @Test func nonRepresentableDateThrows() {
        let value = EpochDate(wrappedValue: Date(timeIntervalSince1970: .infinity))
        #expect(throws: (any Error).self) { try PostcardEncoder().encode(value) }
        #expect(throws: (any Error).self) { try JSONEncoder().encode(value) }
    }

    @Test func malformedGenreIdsDoNotCrash() {
        for value in [
            Filter.Value.select(.init(isGenre: true, options: ["Action"], ids: [])),
            .multiselect(.init(isGenre: true, options: ["Action"], ids: []))
        ] {
            let source = Source(key: "audit", name: "Audit", version: 1, contentRating: .safe,
                staticFilters: [Filter(id: "genre", value: value)], runner: DemoSourceRunner())
            #expect(source.matchingGenreFilter(for: "Action") == nil)
        }
    }
}
