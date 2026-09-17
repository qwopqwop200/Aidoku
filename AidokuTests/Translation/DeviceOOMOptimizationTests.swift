import Darwin
import Foundation
import ImageIO
import Testing
import UIKit
@testable import Aidoku

/// Opt-in device workload; never changes the user's settings or library.
@Suite(.serialized) @MainActor
struct DeviceOOMOptimizationTests {
    private static var root: URL { URL.documentsDirectory.appendingPathComponent("OOMDeviceValidation") }
    private struct Configuration: Decodable {
        let runLabel: String
        let images: [String]
        let expectedHost: String
        let model: String
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("OOMDeviceValidation/config.json").path)))
    func readerAndTranslatedDownloadShareMemoryAdmission() async throws {
        guard #available(iOS 18.0, *) else { return }
        let config = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: Self.root.appendingPathComponent("config.json")))
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"; settings.targetLanguage = "ko"
        settings.rightToLeftPanelOrder = true
        let hasCredential = (try? KeychainTranslationCredentialStore().containsSecret(for: settings.selectedCredentialAccount)) == true
        try #require(hasCredential, "Device translation credential unavailable")
        try #require(URLComponents(string: settings.custom.baseURL)?.host == config.expectedHost)
        try #require(settings.model == config.model)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let output = Self.root.appendingPathComponent(config.runLabel)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sampling = Task.detached(priority: .utility) { () -> [[String: Double]] in
            var rows: [[String: Double]] = []
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                rows.append(["seconds": ProcessInfo.processInfo.systemUptime - started,
                             "footprintMiB": Self.footprintMiB(),
                             "availableMiB": Double(ReaderTranslationSession.processAvailableMemory()) / 1_048_576])
                if rows.count.isMultiple(of: 10) {
                    try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
                        .write(to: output.appendingPathComponent("memory-samples.json"), options: .atomic)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return rows
        }
        defer { sampling.cancel() }
        var rows: [[String: Any]] = []
        func save() throws {
            try JSONSerialization.data(withJSONObject: ["rows": rows, "imageContext": settings.includePageImage,
                "scope": "Physical-device real OCR overlapping translated-download pipeline, saved live provider; app footprint excludes WebKit child process"],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"), options: .atomic)
        }
        try save()
        do {
            await ReaderOCRService.shared.purge()
            for name in config.images {
                let data = try Data(contentsOf: Self.root.appendingPathComponent(name), options: .mappedIfSafe)
                let start = ContinuousClock.now
                let configuration = settings.ocrConfiguration
                async let foreground = Self.recognize(data, configuration: configuration)
                async let translated = DownloadImageTranslator.translate(data, settings: settings)
                let regions = try await foreground
                let result = try await translated
                try result.write(to: output.appendingPathComponent(name + ".translated.png"), options: .atomic)
                #expect(!regions.isEmpty)
                #expect(result.starts(with: [137, 80, 78, 71]))
                let elapsed = start.duration(to: .now).components
                rows.append(["image": name, "milliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                    "ocrRegions": regions.count, "sourceTexts": regions.map(\.source), "outputBytes": result.count,
                    "footprintMiBAfter": Self.footprintMiB(), "thermal": ProcessInfo.processInfo.thermalState.rawValue])
                try save()
                // Exercise the app's actual notification observers without allocating
                // memory to deliberately force a Jetsam termination.
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                UIApplication.shared.delegate?.applicationDidReceiveMemoryWarning?(UIApplication.shared)
                await ReaderOCRService.shared.purge()
                try await Task.sleep(for: .milliseconds(300))
            }
            sampling.cancel()
            let samples = await sampling.value
            try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
                .write(to: output.appendingPathComponent("memory-samples.json"), options: .atomic)
            #expect(!samples.isEmpty)
            await ReaderOCRService.shared.purge()
            ReaderTranslationImageExporter.clearIdleRenderer()
        } catch {
            sampling.cancel()
            let samples = await sampling.value
            try? JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
                .write(to: output.appendingPathComponent("memory-samples.json"), options: .atomic)
            throw error
        }
    }

    private nonisolated static func recognize(_ data: Data, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        try await TranslationImageWorkBudget.shared.withPermit(decodedBytes: TranslationImageWorkBudget.decodedBytes(in: data)) {
            guard let image = UIImage(data: data)?.cgImage else { throw ReaderTranslationImageExporter.ExportError.unavailable }
            return try await ReaderOCRService.shared.recognize(image: image, configuration: configuration)
        }
    }

    private nonisolated static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
