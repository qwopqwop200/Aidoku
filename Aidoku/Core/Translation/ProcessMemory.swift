import Foundation
import os

/// Process memory headroom shared by translation admission.
enum ProcessMemory {
    static func available() -> UInt64 {
        #if os(macOS)
        // os_proc_available_memory is iOS-only.
        return hostFreeAndInactiveMemory()
        #else
        let reported = UInt64(os_proc_available_memory())
        #if targetEnvironment(simulator)
        // The simulator reports zero when headroom is unavailable.
        return reported == 0 ? UInt64.max : reported
        #else
        // iOS apps on Mac (and Catalyst) have no jetsam limit and report 0.
        if reported == 0, ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
            return hostFreeAndInactiveMemory()
        }
        return reported
        #endif
        #endif
    }

    private static func hostFreeAndInactiveMemory() -> UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        return pages.multipliedReportingOverflow(by: UInt64(vm_page_size)).partialValue
    }
}
