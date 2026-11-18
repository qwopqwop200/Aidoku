//
//  NotificationManager.swift
//  Aidoku
//

import Foundation
import UIKit
import UserNotifications

actor NotificationManager {
    static let shared = NotificationManager()

    struct NewChaptersSummary: Sendable {
        let mangaIdentifier: MangaIdentifier
        let mangaTitle: String
        let chapterCount: Int
    }

    static let categoryIdentifier = "newChapters"
    static let threadIdentifier = "newChapters"
    static let sourceIdInfoKey = "sourceId"
    static let mangaIdInfoKey = "mangaId"
    static let batchNotificationThreshold = 3

    struct Client: Sendable {
        var canDeliver: @MainActor @Sendable () -> Bool = {
            AppSettings.library.notifyNewChapters.get() && UIApplication.shared.applicationState == .background
        }
        var authorization: @Sendable () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
        var requestPermission: @Sendable () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        }
        var submit: @Sendable (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        }
    }

    private let client: Client
    private var authorizationRequest: Task<Bool, Never>?

    init(client: Client = .init()) {
        self.client = client
    }

    func requestAuthorization() async -> Bool {
        if let authorizationRequest { return await authorizationRequest.value }
        let request = Task {
            switch await client.authorization() {
                case .authorized, .provisional:
                    return true
                case .notDetermined:
                    return (try? await client.requestPermission()) ?? false
                default:
                    return false
            }
        }
        authorizationRequest = request
        let granted = await request.value
        authorizationRequest = nil
        return granted
    }

    func notifyNewChapters(_ summaries: [NewChaptersSummary]) async {
        guard !summaries.isEmpty, await client.canDeliver() else { return }
        // The chapter writes are already committed. Finish this handoff even if the fetch loop was cancelled.
        await Task { await deliver(summaries) }.value
    }

    private func deliver(_ summaries: [NewChaptersSummary]) async {
        let status = await client.authorization()
        guard status == .authorized || status == .provisional else { return }
        guard await client.canDeliver() else { return }

        if summaries.count > Self.batchNotificationThreshold {
            await sendNotification(
                identifier: "newChapters.batch.\(Int(Date.now.timeIntervalSince1970))",
                title: NSLocalizedString("NEW_CHAPTERS_AVAILABLE"),
                body: String(format: NSLocalizedString("X_SERIES_HAVE_NEW_CHAPTERS"), summaries.count)
            )
            return
        }

        for summary in summaries {
            let timestamp = Int(Date.now.timeIntervalSince1970)
            let identifier = "newChapters.\(summary.mangaIdentifier.sourceKey).\(summary.mangaIdentifier.mangaKey).\(timestamp)"
            await sendNotification(
                identifier: identifier,
                title: summary.mangaTitle,
                body: Self.body(for: summary),
                userInfo: [
                    Self.sourceIdInfoKey: summary.mangaIdentifier.sourceKey,
                    Self.mangaIdInfoKey: summary.mangaIdentifier.mangaKey
                ]
            )
        }
    }

    private func sendNotification(
        identifier: String,
        title: String,
        body: String,
        userInfo: [String: String] = [:]
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = Self.threadIdentifier
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await client.submit(request)
        } catch {
            LogManager.logger.error("Could not submit new chapter notification: \(error.localizedDescription)")
        }
    }

    private static func body(for summary: NewChaptersSummary) -> String {
        if summary.chapterCount == 1 {
            return NSLocalizedString("1_NEW_CHAPTER_AVAILABLE")
        }
        return String(format: NSLocalizedString("X_NEW_CHAPTERS_AVAILABLE"), summary.chapterCount)
    }
}
