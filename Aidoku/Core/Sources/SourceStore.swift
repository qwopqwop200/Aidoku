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

    private struct Snapshot {
        let revision: UInt64
        let sourcesByKey: [String: AidokuRunner.Source]
        let disabledSourceKeys: Set<String>
    }

    @Published private var snapshot = Snapshot(revision: 0, sourcesByKey: [:], disabledSourceKeys: [])
    var sourcesByKey: [String: AidokuRunner.Source] { snapshot.sourcesByKey }
    var disabledSourceKeys: Set<String> { snapshot.disabledSourceKeys }

    func update(
        revision: UInt64,
        sourcesByKey: [String: AidokuRunner.Source],
        disabledSourceKeys: Set<String>
    ) {
        guard revision > snapshot.revision else { return }
        snapshot = Snapshot(revision: revision, sourcesByKey: sourcesByKey, disabledSourceKeys: disabledSourceKeys)
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
