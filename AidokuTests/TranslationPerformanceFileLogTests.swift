import Foundation
import Testing
@testable import Aidoku

struct TranslationPerformanceFileLogTests {
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
