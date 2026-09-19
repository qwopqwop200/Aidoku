//
//  LogStore.swift
//  Aidoku
//
//  Created by Skitty on 5/24/22.
//

import Foundation

actor LogStore {
    nonisolated static let maximumEntries = 10_000
    var entries: [LogEntry] = []
    private var continuations: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    private var streamUrl: URL?
    private var pendingRemoteEntries: [LogEntry] = []
    private var remoteTask: Task<Void, Never>?
    private var remoteGeneration = UUID()

    func addEntry(level: LogType, message: String) {
        let entry = LogEntry(date: Date(), type: level, message: message)
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(max(entries.count - Self.maximumEntries, Self.maximumEntries / 10))
        }
        if streamUrl != nil {
            pendingRemoteEntries.append(entry)
            if pendingRemoteEntries.count > Self.maximumEntries {
                pendingRemoteEntries.removeFirst(Self.maximumEntries / 10)
            }
            if remoteTask == nil {
                let generation = remoteGeneration
                remoteTask = Task { await self.sendPendingEntries(generation: generation) }
            }
        }
        for continuation in continuations.values {
            continuation.yield(entry)
        }
    }

    func clear() {
        entries = []
    }

    func export(to fileUrl: URL) {
        let string = entries
            .map { $0.formatted() }
            .joined(separator: "\n")
        do {
            try string.write(to: fileUrl, atomically: true, encoding: .utf8)
        } catch {
            LogManager.logger.error("Failed to export log store \(error.localizedDescription)")
        }
    }

    func snapshotAndStream() -> ([LogEntry], AsyncStream<LogEntry>) {
        (entries, logStream())
    }

    func logStream() -> AsyncStream<LogEntry> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.maximumEntries)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    func setStreamUrl(_ url: URL?) {
        guard streamUrl != url else { return }
        remoteGeneration = UUID()
        remoteTask?.cancel()
        remoteTask = nil
        pendingRemoteEntries.removeAll()
        streamUrl = url
    }

    private func sendPendingEntries(generation: UUID) async {
        while !Task.isCancelled, generation == remoteGeneration,
              let streamUrl, !pendingRemoteEntries.isEmpty {
            let entry = pendingRemoteEntries.removeFirst()
            var request = URLRequest(url: streamUrl)
            request.httpBody = entry.formatted().data(using: .utf8)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
        if generation == remoteGeneration { remoteTask = nil }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
