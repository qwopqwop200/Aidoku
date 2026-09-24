import os
import Foundation
import Darwin

/// No page text, URLs or credentials. Two bounded files survive an abrupt exit.
enum ReaderTranslationDiagnostics {
    private static let logger = os.Logger(subsystem: "app.aidoku.Aidoku", category: "ReaderPreparation")
    private static let writer = DispatchQueue(label: "app.aidoku.reader-diagnostics", qos: .utility)

    // Opt-in local profiling; no extra event I/O in ordinary reader sessions.
    private static let renderingProfileEnabled: Bool = {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("DisplayPerformance/run.json").path)
    }()

    static func renderingProfile(_ event: String, count: Int = 0, revision: UInt64 = 0) {
        guard renderingProfileEnabled else { return }
        record(event, count: count, code: Int(clamping: revision))
    }

    static func record(_ event: String, page: Int = -1, count: Int = 0, code: Int = 0) {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        let footprint = status == KERN_SUCCESS ? Int64(info.phys_footprint / 1_048_576) : -1
        let available = os_proc_available_memory() / 1_048_576
        let line = "time=\(Date().timeIntervalSince1970) pid=\(ProcessInfo.processInfo.processIdentifier) reader_event=\(event) page=\(page) count=\(count) code=\(code) footprintMiB=\(footprint) availableMiB=\(available)"
        logger.notice("\(line, privacy: .public)")
        writer.async {
            autoreleasepool {
                guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                let url = directory.appendingPathComponent("reader-memory-events.log")
                let previous = directory.appendingPathComponent("reader-memory-events.previous.log")
                do {
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if bytes >= 262_144 {
                        try? FileManager.default.removeItem(at: previous)
                        try FileManager.default.moveItem(at: url, to: previous)
                    }
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(atPath: url.path, contents: nil)
                    }
                    let file = try FileHandle(forWritingTo: url)
                    defer { try? file.close() }
                    try file.seekToEnd()
                    try file.write(contentsOf: Data((line + "\n").utf8))
                } catch { /* Diagnostics must never interfere with the reader. */ }
            }
        }
    }
}
