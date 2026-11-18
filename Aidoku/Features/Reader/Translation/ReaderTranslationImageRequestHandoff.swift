import AidokuRunner
import CryptoKit
import Nuke
import UIKit

/// A native resolver can opt in when it can describe every source-specific input to image authorization.
protocol ReaderImageRequestAuthorityProviding: Sendable {
    func imageRequestAuthority() async -> [String]
}

extension EHentaiSourceRunner: ReaderImageRequestAuthorityProviding {}

final class ReaderTranslationImageRequestHandoff: @unchecked Sendable {
    struct Authority: Equatable {
        let source: ObjectIdentifier
        let url: URL
        let chapter: String
        let index: Int
        let context: PageContext?
        let processorSettings: String
        let width: CGFloat?
        let credentials: Data

        static func capture(url: URL, page: Page, source: AidokuRunner.Source?) async -> Self? {
            guard let source, source.key == page.sourceId, let provider = source.runner as? ReaderImageRequestAuthorityProviding else { return nil }
            let authority = await provider.imageRequestAuthority()
            // A resolver may contact another host before returning a signed image URL.
            // An unrelated cookie change is a conservative miss. Keep only a digest.
            let now = Date()
            let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter { ($0.expiresDate ?? .distantFuture) > now }.map {
                [$0.domain, $0.path, $0.name, $0.value, String($0.isSecure), String($0.isHTTPOnly),
                 String($0.expiresDate?.timeIntervalSince1970 ?? 0)]
            }.sorted { $0.lexicographicallyPrecedes($1) }
            guard let bytes = try? JSONEncoder().encode([authority] + cookies) else { return nil }
            let (processors, width) = await MainActor.run {
                let width = UserDefaults.standard.bool(forKey: "Reader.downsampleImages") ? UIScreen.main.bounds.width : nil
                return (ImageProcessingSettingsKey.getProcessorSettingsKey(), width)
            }
            return Self(source: ObjectIdentifier(source), url: url, chapter: page.chapterId, index: page.index, context: page.context,
                        processorSettings: processors, width: width, credentials: Data(SHA256.hash(data: bytes)))
        }
    }

    private let lock = NSLock()
    private weak var source: AidokuRunner.Source?
    private var prepared: (Authority, ImageRequest)?
    private var transfer: ImageTask?
    private var finished = false
    private var discarded = false
    private var promoted = false
    private var demandReserved = false
    private var demand: (BulkDownloadAdmission, UUID)?

    func save(_ request: ImageRequest, authority: Authority, source: AidokuRunner.Source?) {
        lock.withLock {
            guard !discarded else { return }
            self.source = source
            prepared = (authority, request)
        }
    }

    var hasPreparedRequest: Bool { lock.withLock { prepared != nil } }

    func take(for authority: Authority?, source: AidokuRunner.Source?) -> ImageRequest? {
        lock.withLock {
            defer { prepared = nil; self.source = nil }
            guard let authority, let prepared, self.source === source, prepared.0 == authority else { return nil }
            var request = prepared.1
            // Even eviction after this check cannot send an old signed URL to the network.
            request.options.insert(.returnCacheDataDontLoad)
            return request
        }
    }

    func startTransfer(_ task: ImageTask, foreground: Bool, admission: BulkDownloadAdmission) async throws {
        let shouldPromote = lock.withLock {
            guard !discarded else { task.cancel(); return false }
            transfer = task
            return promoted || foreground
        }
        if shouldPromote {
            do { try await promote(admission: admission) }
            catch { task.cancel(); throw error }
        }
    }

    func promote(admission: BulkDownloadAdmission) async throws {
        let acquire = lock.withLock {
            guard !finished, !discarded else { return false }
            promoted = true
            guard let transfer, !demandReserved else { return false }
            transfer.priority = .high
            demandReserved = true
            return true
        }
        guard acquire else { return }
        let token: UUID
        do { token = try await admission.acquireReaderDemand() }
        catch {
            lock.withLock { demandReserved = false }
            throw error
        }
        let release = lock.withLock {
            guard !finished, !discarded else { return true }
            demand = (admission, token)
            return false
        }
        if release { await admission.releaseReaderDemand(token) }
    }

    func finishTransfer() {
        let released = lock.withLock {
            finished = true
            transfer = nil
            defer { demand = nil }
            return demand
        }
        if let (admission, token) = released { Task { await admission.releaseReaderDemand(token) } }
    }

    func discard() {
        lock.withLock {
            discarded = true
            prepared = nil
            source = nil
            transfer?.cancel()
        }
        finishTransfer()
    }
}
