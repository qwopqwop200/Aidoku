//
//  SourceStore.swift
//  Aidoku
//
//  Created by skitty on 8/25/26.
//

import AidokuRunner
import Foundation

@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()

    @Published private(set) var sourcesByKey: [String: AidokuRunner.Source] = [:]
    @Published private(set) var disabledSourceKeys: Set<String> = []
    private var revision: UInt64 = 0

    func update(
        revision: UInt64,
        sourcesByKey: [String: AidokuRunner.Source],
        disabledSourceKeys: Set<String>
    ) {
        guard revision > self.revision else { return }
        self.revision = revision
        self.sourcesByKey = sourcesByKey
        self.disabledSourceKeys = disabledSourceKeys
    }

    func source(for key: String) -> AidokuRunner.Source? {
        sourcesByKey[key]
    }

    func isInstalled(sourceKey: String) -> Bool {
        sourcesByKey[sourceKey] != nil
    }

    func isDisabled(sourceKey: String) -> Bool {
        disabledSourceKeys.contains(sourceKey)
    }

    var localSourceInstalled: Bool {
        sourcesByKey[LocalSourceRunner.sourceKey] != nil
    }
}
