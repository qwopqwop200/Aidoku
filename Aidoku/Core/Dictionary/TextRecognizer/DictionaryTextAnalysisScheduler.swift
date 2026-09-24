//
//  DictionaryTextAnalysisScheduler.swift
//  Aidoku
//
//  Created by skitty on 7/19/26.
//

import UIKit

@available(iOS 18.0, *)
actor DictionaryTextAnalysisQueue {
    static let shared = DictionaryTextAnalysisQueue()

    private var isRunning = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    var queuedCount: Int { waiters.count }

    func waitForTurn() async throws {
        try Task.checkCancellation()
        if !isRunning {
            isRunning = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func finishTurn() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    func run(_ operation: () async -> Void) async {
        do { try await waitForTurn() } catch { return }
        defer { finishTurn() }
        guard !Task.isCancelled else { return }
        await operation()
    }
}

@available(iOS 18.0, *)
enum DictionaryTextAnalysisScheduler {
    static func cancel(
        task: inout Task<Void, Never>?,
        recognizer: TextRecognizer?
    ) {
        task?.cancel()
        task = nil
        recognizer?.reset()
    }

    static func schedule(
        task: inout Task<Void, Never>?,
        recognizer: inout TextRecognizer?,
        image: UIImage?,
        language: String?,
        onFinish: @MainActor @Sendable @escaping () -> Void
    ) {
        task?.cancel()
        guard
            AppSettings.dictionary.isOCREnabled(language: language),
            let image
        else {
            recognizer?.reset()
            task = nil
            return
        }

        let runRecognizer = TextRecognizer()
        recognizer = runRecognizer
        task = Task { [weak runRecognizer] in
            await DictionaryTextAnalysisQueue.shared.run {
                guard !Task.isCancelled, let runRecognizer else { return }
                await runRecognizer.analyze(image, language: language)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    onFinish()
                }
            }
        }
    }
}
