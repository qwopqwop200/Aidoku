import Foundation
import Testing
@testable import Aidoku

struct TranslationPerformanceFileLogTests {
    @Test func burstsUseOneWriteAndOneMemorySampleWithBoundedOverflow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TranslationPerformanceFileWriter(directory: directory, maximumPending: 128,
            filename: "reader-memory-events", samplesMemory: true, flushInterval: 60)
        let context = ReaderTranslationDiagnostics.makeContext(pageKey: String(repeating: "a", count: 64), page: 60)
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<256 {
            writer.recordReader("test_stage", page: -1, count: index, code: 0, context: context)
        }
        let producerMicroseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000_000 / 256
        writer.flushForTesting()
        let current = try String(contentsOf: directory.appendingPathComponent("reader-memory-events.log"), encoding: .utf8)
        #expect(current.split(separator: "\n").count == 128)
        #expect(current.contains("dropped=128"))
        #expect(current.contains("page=60"))
        #expect(current.contains("page_token=aaaaaaaaaaaaaaaa"))
        #expect(writer.writeBatchCount == 1)
        #expect(writer.memorySampleCount == 1)
        #expect(current.contains("memory_sample_uptime="))
        print("DIAGNOSTIC_BURST producer_us_per_call=\(producerMicroseconds) accepted=128 dropped=128 file_writes=\(writer.writeBatchCount)")
    }

    @Test func traceSurvivesExplicitDetachedHandoffAndRestoresCaller() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TranslationPerformanceFileWriter(directory: directory, flushInterval: 60)
        let context = ReaderTranslationDiagnostics.makeContext(pageKey: String(repeating: "b", count: 64), page: 60)
        await Task.detached {
            await ReaderTranslationDiagnostics.measure("test_handoff", context: context) {
                writer.record(.readerOCR, fields: [.elapsedMilliseconds: 3])
                await Task { writer.record(.providerQueue, fields: [.elapsedMilliseconds: 4]) }.value
            }
            #expect(ReaderTranslationDiagnostics.context == nil)
        }.value
        writer.flushForTesting()
        let lines = try String(contentsOf: directory.appendingPathComponent("translation-performance.log"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("trace=\(context.trace)") && $0.contains("page=60") })
        #expect(ReaderTranslationDiagnostics.context == nil)
    }

    @Test func readerEventsRejectAccidentalContentAndPreserveOutcome() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TranslationPerformanceFileWriter(directory: directory, flushInterval: 60)
        for event in ["https://private.invalid/key", "source text", String(repeating: "a", count: 81)] {
            writer.recordReader(event, page: -1, count: 0, code: 0, context: nil)
        }
        writer.recordReader("export_render_end", page: 60, count: 0, code: -999, context: nil, elapsedMilliseconds: 12, outcome: 1)
        writer.flushForTesting()
        let current = try String(contentsOf: directory.appendingPathComponent("translation-performance.log"), encoding: .utf8)
        #expect(current.split(separator: "\n").count == 1)
        #expect(current.contains("outcome=1") && current.contains("code=-999"))
        #expect(!current.contains("private.invalid"))
    }

    @Test func phaseAllowlistRejectsContentAndIncludesAdmissionPhases() {
        #expect(TranslationPerformanceFileLog.Event(rawValue: "https://example.test/private") == nil)
        #expect(TranslationPerformanceFileLog.Event(rawValue: "arbitrary page text") == nil)
        #expect(TranslationPerformanceFileLog.Event(rawValue: "provider_queue") == .providerQueue)
        #expect(TranslationPerformanceFileLog.Event(rawValue: "persistence_admission") == .persistenceAdmission)
        #expect(TranslationPerformanceFileLog.Event(rawValue: "provider_client") == .providerClient)
    }

    @Test func rotationBoundsBothFilesAndPreservesNewestEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TranslationPerformanceFileWriter(directory: directory, maximumBytes: 512)
        for index in 0..<20 {
            writer.record(.transport, fields: [.segments: Double(index), .totalMilliseconds: 123])
        }
        writer.flushForTesting()
        for filename in ["translation-performance.log", "translation-performance.previous.log"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(filename))
            #expect(data.count <= 512)
            #expect(!data.isEmpty)
        }
        let current = try String(contentsOf: directory.appendingPathComponent("translation-performance.log"), encoding: .utf8)
        #expect(current.contains("segments=19.0"))
        #expect(current.contains("pipeline_event=transport"))
    }

    @Test func nonfiniteMetricsAreOmittedAndUnavailableSentinelSurvives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TranslationPerformanceFileWriter(directory: directory)
        writer.record(.transport, fields: [.bodyMilliseconds: .nan, .totalMilliseconds: .infinity, .responseHeadersMilliseconds: -1])
        writer.flushForTesting()
        let current = try String(contentsOf: directory.appendingPathComponent("translation-performance.log"), encoding: .utf8)
        #expect(!current.contains("body_ms="))
        #expect(!current.contains("total_ms="))
        #expect(current.contains("response_headers_ms=-1.0"))
    }
}
