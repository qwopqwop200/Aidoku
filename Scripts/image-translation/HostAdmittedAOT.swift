import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reached only by the current launcher's explicit --admitted-aot-request option.
/// JSON contains current inventory and separately sealed admission. No text image input.
@main enum HostAdmittedAOT {
    struct Request: Decodable {
        let source: String
        let mask: String
        let installedModel: String?
        let output: String
        let enabled: Bool
        let admission: NativeAdmittedAOTPageRoute.Admission
        let current: NativeAdmittedAOTPageRoute.Inventory
    }
    static func load(_ path: String) throws -> CGImage {
        guard let decoder = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }
    static func save(_ image: CGImage, at url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
    static func main() async {
        do { try await execute() }
        catch {
            FileHandle.standardError.write(Data("admitted-aot error: \(String(describing: error))\n".utf8))
            exit(1)
        }
    }
    static func execute() async throws {
        guard CommandLine.arguments.count == 2 else { throw NativeAdmittedAOTPageRoute.Failure.invalidAdmission }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let output = URL(fileURLWithPath: request.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let source = try load(request.source), maskImage = try load(request.mask)
        guard source.width == maskImage.width, source.height == maskImage.height else {
            throw NativeAdmittedAOTPageRoute.Failure.invalidAdmission
        }
        let rgba = try NativeAdmittedAOTPageRoute.rgba(maskImage)
        var binary: [UInt8] = []
        binary.reserveCapacity(source.width * source.height)
        for p in stride(from: 0, to: rgba.count, by: 4) {
            guard rgba[p] == rgba[p + 1], rgba[p] == rgba[p + 2], rgba[p + 3] == 255,
                  rgba[p] == 0 || rgba[p] == 255 else { throw NativeAdmittedAOTPageRoute.Failure.invalidAdmission }
            binary.append(rgba[p] == 0 ? 0 : 1)
        }
        let result = try await NativeAdmittedAOTPageRoute.shared.render(source: source, binaryMask: binary,
            admission: request.admission, current: request.current,
            installedModelURL: request.installedModel.map { URL(fileURLWithPath: $0) }, enabled: request.enabled)
        // Refuse output reuse rather than overwrite a frozen result.
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try save(result.restored, at: output.appendingPathComponent("restored.png"))
        try save(result.text, at: output.appendingPathComponent("text.png"))
        try save(result.final, at: output.appendingPathComponent("final.png"))
        try result.audit.write(to: output.appendingPathComponent("audit.json"), options: .atomic)
        print("admitted-aot complete \(result.identity) owners=\(request.current.owners.count)")
    }
}
