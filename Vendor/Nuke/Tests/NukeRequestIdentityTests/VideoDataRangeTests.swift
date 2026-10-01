#if !os(watchOS)
import Foundation
import Testing
@testable import NukeVideo

struct VideoDataRangeTests {
    @Test func rangeReadsPreserveBytesAndClampEOFProbes() throws {
        let bytes = Data([0, 1, 2, 3, 4])
        #expect(try videoDataRange(bytes, offset: 1, length: 2, toEnd: false) == Data([1, 2]))
        #expect(try videoDataRange(bytes, offset: 3, length: Int.max, toEnd: false) == Data([3, 4]))
        #expect(try videoDataRange(bytes, offset: 3, length: 0, toEnd: true) == Data([3, 4]))
        #expect(try videoDataRange(bytes, offset: 5, length: 2, toEnd: false).isEmpty)
        let slice = bytes[2...]
        #expect(try videoDataRange(slice, offset: 0, length: 2, toEnd: false) == Data([2, 3]))
    }

    @Test(arguments: [Int64(-1), 6, Int64.max])
    func invalidOffsetsFailWithoutTrapping(offset: Int64) {
        #expect(throws: URLError.self) {
            try videoDataRange(Data([0, 1, 2, 3, 4]), offset: offset, length: 1, toEnd: false)
        }
    }
}
#endif
