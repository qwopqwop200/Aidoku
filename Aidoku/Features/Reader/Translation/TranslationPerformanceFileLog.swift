import Foundation
import Darwin

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

/// Bounded admission and one delayed drain, rather than one closure/open/write per event.
/// Producers only retain scalar metrics. Formatting, memory sampling and file I/O run on utility.
final class TranslationPerformanceFileWriter: @unchecked Sendable {
    private struct Entry {
        let sequence: UInt64
        let timestamp: TimeInterval
        let uptime: TimeInterval
        let event: String
        let reader: Bool
        let fields: [TranslationPerformanceFileLog.Field: Double]
        let context: ReaderTranslationDiagnostics.Context?
        let page: Int
        let count: Int
        let code: Int
        let elapsed: Double?
        let outcome: Int
    }
    private let directory: URL
    private let maximumBytes: Int
    private let maximumPending: Int
    private let filename: String
    private let samplesMemory: Bool
    private let flushInterval: TimeInterval
    private let queue = DispatchQueue(label: "app.aidoku.translation-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var scheduled = false
    private var sequence: UInt64 = 0
    private var dropped = 0
    private var writeFailures = 0 // Writer queue only.
    private var memorySample: (uptime: TimeInterval, footprint: Int64, available: UInt64) = (-1, -1, 0)
    private(set) var writeBatchCount = 0 // Read only after flushForTesting.
    private(set) var memorySampleCount = 0

    init(directory: URL, maximumBytes: Int = 524_288, maximumPending: Int = 256,
         filename: String = "translation-performance", samplesMemory: Bool = false, flushInterval: TimeInterval = 0.25) {
        self.directory = directory
        self.maximumBytes = max(1, maximumBytes)
        self.maximumPending = max(1, maximumPending)
        self.filename = filename
        self.samplesMemory = samplesMemory
        self.flushInterval = flushInterval
    }

    func record(_ event: TranslationPerformanceFileLog.Event, fields: [TranslationPerformanceFileLog.Field: Double]) {
        enqueue(event: event.rawValue, reader: false, fields: fields, context: ReaderTranslationDiagnostics.context)
    }

    func recordReader(_ event: String, page: Int, count: Int, code: Int, context: ReaderTranslationDiagnostics.Context?,
                      elapsedMilliseconds: Double? = nil, outcome: Int = 0) {
        // Existing reader call sites use constant event names. Reject accidental text/URLs.
        guard !event.isEmpty, event.utf8.count <= 80,
              event.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return }
        enqueue(event: event, reader: true, fields: [:], context: context, page: page, count: count, code: code,
                elapsed: elapsedMilliseconds, outcome: outcome)
    }

    private func enqueue(event: String, reader: Bool, fields: [TranslationPerformanceFileLog.Field: Double],
                         context: ReaderTranslationDiagnostics.Context?, page: Int = -1, count: Int = 0,
                         code: Int = 0, elapsed: Double? = nil, outcome: Int = 0) {
        let timestamp = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        let shouldSchedule = lock.withLock {
            sequence &+= 1
            guard pending.count < maximumPending else { dropped += 1; return false }
            pending.append(Entry(sequence: sequence, timestamp: timestamp, uptime: uptime, event: event, reader: reader,
                fields: fields, context: context, page: page, count: count, code: code, elapsed: elapsed, outcome: outcome))
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule { queue.asyncAfter(deadline: .now() + flushInterval) { [self] in drain() } }
    }

    /// Explicit test barrier only; production readers never wait for disk.
    func flushForTesting() { queue.sync { drain() } }

    private func drain() {
        let batch: ([Entry], Int) = lock.withLock {
            let batch = (pending, dropped)
            pending = []
            dropped = 0
            scheduled = false
            return batch
        }
        guard !batch.0.isEmpty else { return }
        autoreleasepool {
            let now = ProcessInfo.processInfo.systemUptime
            if samplesMemory, memorySample.uptime < 0 || now - memorySample.uptime >= 1 {
                var info = task_vm_info_data_t()
                var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let status = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
                    }
                }
                memorySample = (now, status == KERN_SUCCESS ? Int64(info.phys_footprint / 1_048_576) : -1,
                                UInt64(os_proc_available_memory() / 1_048_576))
                memorySampleCount += 1
            }
            let lines = batch.0.enumerated().map { index, entry -> Data in
                var line = "time=\(entry.timestamp) uptime=\(entry.uptime) pid=\(ProcessInfo.processInfo.processIdentifier) seq=\(entry.sequence) "
                line += "\(entry.reader ? "reader_event" : "pipeline_event")=\(entry.event) dropped=\(index == 0 ? batch.1 : 0) write_failures=\(writeFailures)"
                if let context = entry.context {
                    line += " trace=\(context.trace) page_token=\(String(context.pageToken, radix: 16))"
                }
                line += " page=\(entry.page >= 0 ? entry.page : entry.context?.page ?? -1)"
                if entry.reader {
                    line += " count=\(entry.count) code=\(entry.code) outcome=\(entry.outcome)"
                    if let elapsed = entry.elapsed, elapsed.isFinite { line += " elapsed_ms=\(elapsed)" }
                } else {
                    for (key, value) in entry.fields.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where value.isFinite {
                        line += " \(key.rawValue)=\(value)"
                    }
                }
                if samplesMemory {
                    line += " footprintMiB=\(memorySample.footprint) availableMiB=\(memorySample.available) memory_sample_uptime=\(memorySample.uptime)"
                }
                return Data((line + "\n").utf8)
            }
            append(lines)
        }
    }

    private func append(_ lines: [Data]) {
        let url = directory.appendingPathComponent(filename + ".log")
        let previous = directory.appendingPathComponent(filename + ".previous.log")
        var file: FileHandle?
        defer { try? file?.close() }
        do {
            var bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var buffer = Data()
            func writeBuffer() throws {
                guard !buffer.isEmpty else { return }
                if file == nil {
                    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                    file = try FileHandle(forWritingTo: url)
                    try file?.seekToEnd()
                }
                try file?.write(contentsOf: buffer)
                writeBatchCount += 1
                buffer.removeAll(keepingCapacity: true)
            }
            for line in lines where line.count <= maximumBytes {
                if bytes + line.count > maximumBytes {
                    try writeBuffer()
                    try file?.close(); file = nil
                    try? FileManager.default.removeItem(at: previous)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: url, to: previous) }
                    bytes = 0
                }
                buffer.append(line)
                bytes += line.count
            }
            try writeBuffer()
        } catch { writeFailures += 1 } // Logging can never change reader outcomes.
    }
}
