import Foundation

@main struct NativeFinalSegmentationReplay {
    struct Input: Decodable {
        let width: Int
        let height: Int
        let base: [UInt8]
        let primary: [Float]
        let boundary: [Float]
        let jointCodes: [UInt16]
        let style: [Double]
        let auxiliaryCodes: [UInt16]
    }
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--segmentation-final-jsonl" {
            try NativeSegmentationFinalStream.run()
            return
        }
        while let line = readLine() {
            do {
                let i = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
                let result = try NativeSegmentationFinalPolicy.apply(.init(width: i.width, height: i.height,
                    base: i.base, primary: i.primary, boundary: i.boundary, jointCodes: i.jointCodes,
                    style: i.style, auxiliaryCodes: i.auxiliaryCodes))
                let data = try JSONSerialization.data(withJSONObject: ["mask": result.mask, "auxiliaryRemoved": result.auxiliaryRemoved,
                    "policySHA256": NativeSegmentationFinalPolicy.policySHA256, "GTRead": false])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                print("{\"error\":\"invalid-source-observations\"}")
            }
        }
    }
}
