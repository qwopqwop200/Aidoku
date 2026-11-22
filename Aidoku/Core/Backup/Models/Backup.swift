//
//  Backup.swift
//  Aidoku
//
//  Created by Skitty on 2/26/22.
//

import Foundation

struct Backup: Codable, Hashable, Identifiable, Sendable {
    var id: Int { hashValue }

    var library: [BackupLibraryManga]?
    var history: [BackupHistory]?
    var manga: [BackupManga]?
    var chapters: [BackupChapter]?
    var trackItems: [BackupTrackItem]?
    var readingSessions: [BackupReadingSession]?
    var vocabulary: [BackupVocabEntry]?
    var updates: [BackupUpdate]?
    var categories: [BackupCategory]?
    var sources: [BackupSource]?
    var sourceLists: [String]?
    var settings: [String: JSONAnyValue]?
    var date: Date
    var name: String?
    var automatic: Bool?
    var version: String?

    static func load(from url: URL) -> Backup? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> Backup? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let json = { try? decoder.decode(Backup.self, from: data) }
        let plist = { try? PropertyListDecoder().decode(Backup.self, from: data) }
        return data.first == UInt8(ascii: "{") ? json() ?? plist() : plist() ?? json()
    }
}
