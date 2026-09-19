//
//  LookupEngine.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Based on: https://github.com/Manhhao/Hoshi-Reader/blob/c31c9d0ce376ff83bf6a91d908bf9f8e0fb4947b/Core/LookupEngine.swift
//  Modified for use in Aidoku
//

import Foundation
import UIKit
import CHoshiDicts
import CxxStdlib

@available(iOS 18.0, macOS 15.0, *)
@MainActor
class LookupEngine {
    static let shared = LookupEngine()

    private nonisolated final class Bundle: @unchecked Sendable {
        var dictQuery = DictionaryQuery()
        var deinflector = Deinflector()
        var lookup: Lookup!
        var loadFailed = false

        init(termPaths: [URL], freqPaths: [URL], pitchPaths: [URL], kanjiPaths: [URL]) {
            for path in termPaths {
                dictQuery.add_term_dict(std.string(path.path(percentEncoded: false)))
                loadFailed = dictQuery.has_error() || loadFailed
            }
            for path in freqPaths {
                dictQuery.add_freq_dict(std.string(path.path(percentEncoded: false)))
                loadFailed = dictQuery.has_error() || loadFailed
            }
            for path in pitchPaths {
                dictQuery.add_pitch_dict(std.string(path.path(percentEncoded: false)))
                loadFailed = dictQuery.has_error() || loadFailed
            }
            for path in kanjiPaths {
                dictQuery.add_kanji_dict(std.string(path.path(percentEncoded: false)))
                loadFailed = dictQuery.has_error() || loadFailed
            }
            lookup = Lookup(&dictQuery, &deinflector)
        }
    }

    private var bundle: Bundle?
    private var generation = 0
    private weak var errorAlert: UIAlertController?

    private func reportLookupError() {
        guard errorAlert == nil,
              let controller = UIApplication.shared.appDelegate?.topViewController else { return }
        let alert = UIAlertController(
            title: NSLocalizedString("DICTIONARY_LOOKUP"),
            message: NSLocalizedString("DECODING_ERROR"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
        errorAlert = alert
        controller.present(alert, animated: true)
    }
    private var buildTask: Task<Void, Never>?

    var isReady: Bool {
        bundle != nil
    }

    private init() {}

    func buildQuery(termPaths: [URL], freqPaths: [URL], pitchPaths: [URL], kanjiPaths: [URL]) {
        generation += 1
        let token = generation
        let previous = buildTask
        buildTask = Task.detached(priority: .userInitiated) {
            await previous?.value
            guard await MainActor.run(body: { token == self.generation }) else { return }
            let newBundle = Bundle(termPaths: termPaths, freqPaths: freqPaths, pitchPaths: pitchPaths, kanjiPaths: kanjiPaths)
            await MainActor.run {
                guard token == self.generation else { return }
                self.bundle = newBundle
                if newBundle.loadFailed { self.reportLookupError() }
            }
        }
    }

    func lookup(_ str: String, maxResults: Int = 16, scanLength: Int = 16) -> [LookupResult] {
        guard let bundle else { return [] }
        guard !bundle.loadFailed else {
            reportLookupError()
            return []
        }
        guard maxResults > 0, scanLength > 0 else { return [] }
        let results = bundle.lookup.lookup(std.string(str), Int32(clamping: maxResults), scanLength, LookupOptions())
        guard !bundle.dictQuery.has_error() else {
            reportLookupError()
            return []
        }
        return Array(results)
    }

    func queryKanji(_ kanji: String) -> [String: Any]? {
        guard let bundle else { return nil }
        guard !bundle.loadFailed else {
            reportLookupError()
            return nil
        }
        let result = bundle.dictQuery.query_kanji(std.string(kanji))
        guard !bundle.dictQuery.has_error() else {
            reportLookupError()
            return nil
        }
        var entries: [[String: Any]] = []
        for entry in result.entries {
            var meanings: [String] = []
            for definition in entry.definitions {
                meanings.append(String(definition))
            }
            entries.append([
                "dictName": String(entry.dict_name),
                "onyomi": String(entry.onyomi),
                "kunyomi": String(entry.kunyomi),
                "meanings": meanings
            ])
        }
        guard !entries.isEmpty else { return nil }
        return [
            "character": String(result.character),
            "entries": entries
        ]
    }

    func getStyles() -> [DictionaryStyle] {
        guard let bundle else { return [] }
        let styles = bundle.dictQuery.get_styles()
        guard !bundle.dictQuery.has_error() else {
            reportLookupError()
            return []
        }
        return Array(styles)
    }

    func withMediaFile<T>(dictName: String, mediaPath: String, _ body: (Data) -> T) -> T {
        guard let bundle else { return body(Data()) }
        let view = bundle.dictQuery.get_media_file_view(std.string(dictName), std.string(mediaPath))
        guard !bundle.dictQuery.has_error() else {
            reportLookupError()
            return body(Data())
        }
        let size = Int(view.size)
        guard size > 0, let ptr = UnsafeMutableRawPointer(mutating: view.data) else {
            return body(Data())
        }
        let data = Data(bytesNoCopy: ptr, count: size, deallocator: .none)
        return body(data)
    }

    func getMediaFile(dictName: String, mediaPath: String) -> Data {
        withMediaFile(dictName: dictName, mediaPath: mediaPath) { data in
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return Data() }
                return Data(bytes: baseAddress, count: buffer.count)
            }
        }
    }
}
