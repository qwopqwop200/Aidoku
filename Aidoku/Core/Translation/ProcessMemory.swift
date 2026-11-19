import Foundation
import os

/// Process memory headroom shared by translation admission (image work budget,
/// Core ML recognizer). Extracted from the reader translation session.
enum ProcessMemory {
    static func available() -> UInt64 {
        #if os(macOS)
        // Mac host tools: os_proc_available_memory is iOS-only. Use the same
        // free + inactive vm_statistics64 estimate as the image-translation host.
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * UInt64(vm_page_size)
        #else
        let reported = UInt64(os_proc_available_memory())
        #if targetEnvironment(simulator)
        // Simulator reports zero when process headroom is unavailable. Explicit
        // test budgets and all physical-device values still use the normal gate.
        return reported == 0 ? UInt64.max : reported
        #else
        return reported
        #endif
        #endif
    }
}
