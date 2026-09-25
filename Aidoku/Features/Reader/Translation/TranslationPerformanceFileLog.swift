import Foundation

/// A content-free device-readable counterpart to OSLog. Only closed event/field
/// enums and finite numbers cross this boundary; no text, URL, model or key can.
enum TranslationPerformanceFileLog {
    enum Event: String, Sendable {
        case service, providerAttempt, providerFailure, transport, batch
        case endpoint, keychain, encode, parse
        case providerQueue = "provider_queue"
        case persistenceAdmission = "persistence_admission"
        case providerClient = "provider_client"
        case readerImageLoad = "reader_image_load"
        case readerOCR = "reader_ocr"
        case readerOCRAhead = "reader_ocr_ahead"
        case readerLayout = "reader_layout"
        case readerSnapshot = "reader_snapshot"
        case ocrQueue = "ocr_queue"
        case ocrFrame = "ocr_frame"
        case ocrDetection = "ocr_detection"
        case ocrRecognition = "ocr_recognition"
        case ocrPostprocess = "ocr_postprocess"
    }

    enum Field: String, Sendable {
        case elapsedMilliseconds = "elapsed_ms"
        case segments, attempt, retry, reason, source, priority
        case sourceBytes = "source_bytes"
        case responseBytes = "response_bytes"
        case statusClass = "status_class"
        case responseHeadersMilliseconds = "response_headers_ms"
        case firstBodyByteMilliseconds = "first_body_byte_ms"
        case bodyMilliseconds = "body_ms"
        case totalMilliseconds = "total_ms"
        case batchCount = "batch_count"
    }

    private static let sink: TranslationPerformanceFileWriter? = {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return TranslationPerformanceFileWriter(directory: directory)
    }()

    static func record(_ event: Event, fields: [Field: Double]) {
        sink?.record(event, fields: fields)
    }
}

/// Queue admission is bounded as well as the two files, so a slow filesystem
/// cannot retain unlimited diagnostic work. No fsync or reader-thread file I/O.
final class TranslationPerformanceFileWriter: @unchecked Sendable {
    private let directory: URL
    private let maximumBytes: Int
    private let maximumPending: Int
    private let queue = DispatchQueue(label: "app.aidoku.translation-performance", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0

    init(directory: URL, maximumBytes: Int = 524_288, maximumPending: Int = 128) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumPending = maximumPending
    }

    func record(_ event: TranslationPerformanceFileLog.Event, fields: [TranslationPerformanceFileLog.Field: Double]) {
        let admission: Int? = lock.withLock {
            guard pending < maximumPending else { dropped += 1; return nil }
            pending += 1
            let value = dropped
            dropped = 0
            return value
        }
        guard let dropped = admission else { return }
        let timestamp = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            autoreleasepool {
                let values = fields.filter { $0.value.isFinite }.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
                let line = "time=\(timestamp) uptime=\(uptime) pid=\(ProcessInfo.processInfo.processIdentifier) pipeline_event=\(event.rawValue) dropped=\(dropped) \(values)\n"
                append(Data(line.utf8))
            }
        }
    }

    /// Test-only barrier. Production callers never wait for the filesystem.
    func flushForTesting() { queue.sync {} }

    private func append(_ data: Data) {
        guard data.count <= maximumBytes else { return }
        let url = directory.appendingPathComponent("translation-performance.log")
        let previous = directory.appendingPathComponent("translation-performance.previous.log")
        do {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if bytes + data.count > maximumBytes {
                try? FileManager.default.removeItem(at: previous)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.moveItem(at: url, to: previous)
                }
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
        } catch { /* Diagnostics must never change translation outcomes. */ }
    }
}
