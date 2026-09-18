//
//  ModelManager.swift
//  Aidoku
//

import CoreML
import CryptoKit

struct ModelList: Decodable {
    let models: [ModelInfo]
}

struct ModelInfo: Codable {
    var name: String?
    var info: String?
    var tags: [String]?
    var type: String?
    var miniOS: Int?
    var config: [String: JSONAnyValue]?
    var file: String
    var size: Int?
    var bundledResource: String?
    var sha256: String?
    var infoKO: String?

    var localizedInfo: String? {
        localizedInfo(bundle: .main)
    }

    func localizedInfo(bundle: Bundle) -> String? {
        // Translate bundled descriptions while preserving attribution and license text verbatim.
        let summary: String?
        switch bundledResource == nil ? "" : file {
        case "SwinUNetV3Art2x.mlpackage":
            summary = Foundation.NSLocalizedString("UPSCALE_MODEL_SWINUNET_INFO", bundle: bundle, comment: "")
        case "IllustrationJaNaiV3-FDATM.mlpackage":
            summary = Foundation.NSLocalizedString("UPSCALE_MODEL_ILLUSTRATIONJANAI_INFO", bundle: bundle, comment: "")
        case "UltraSharpV2Lite.mlpackage":
            summary = Foundation.NSLocalizedString("UPSCALE_MODEL_ULTRASHARP_INFO", bundle: bundle, comment: "")
        case "AnimeSharpV4.mlpackage":
            summary = Foundation.NSLocalizedString("UPSCALE_MODEL_ANIMESHARP_INFO", bundle: bundle, comment: "")
        case "MangaJaNaiV1-4x1200p.mlpackage":
            summary = Foundation.NSLocalizedString("UPSCALE_MODEL_MANGAJANAI_INFO", bundle: bundle, comment: "")
        default:
            summary = nil
        }
        if let summary, !summary.hasPrefix("UPSCALE_MODEL_") {
            let attribution = info.flatMap { text in
                text.range(of: "\n\n").map { String(text[$0.lowerBound...]) }
            } ?? ""
            return summary + attribution
        }
        let language = bundle.bundleURL.pathExtension == "lproj"
            ? bundle.bundleURL.deletingPathExtension().lastPathComponent
            : bundle.preferredLocalizations.first
        if language?.hasPrefix("ko") == true, let infoKO { return infoKO }
        return info
    }
}

actor ModelManager {
    static let shared = ModelManager()
    private static let modelListUrl = URL(string: "https://upscale.aidoku.app/models.json")!
    private static let supportedModelTypes: Set<String> = ["multiarray", "image"]

    private let directory: URL
    private let bundle: Bundle
    private var imageModelCache: [String: ImageProcessingModel] = [:]
    private var cachedModelList: ModelList?
    private var installing: Set<String> = []

    init(directory: URL? = nil, bundle: Bundle = .main) {
        self.directory = directory ?? FileManager.default.documentDirectory.appendingPathComponent("Models")
        self.bundle = bundle
    }

    enum InstallationError: Error {
        case invalidFile, missingResource, invalidChecksum, invalidResponse, alreadyInstalling, invalidModel
    }

    func bundledModels() -> [ModelInfo] {
        guard let url = bundle.url(forResource: "UpscaleModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ModelList.self, from: data) else { return [] }
        return list.models
    }

    // Stage extraction and metadata together. A failed install never appears in the installed list.
    func downloadModel(_ model: ModelInfo) async throws {
        let fileName = (model.file as NSString).lastPathComponent
        guard !fileName.isEmpty, ["mlpackage", "mlmodel"].contains((fileName as NSString).pathExtension) else {
            throw InstallationError.invalidFile
        }
        guard installing.insert(fileName).inserted else { throw InstallationError.alreadyInstalling }
        defer { installing.remove(fileName) }
        let fm = FileManager.default
        let root = try modelsDirectory()
        let staging = root.appendingPathComponent(".install-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedModel = staging.appendingPathComponent(fileName)
        let source: URL
        if let resource = model.bundledResource {
            // Only the app's own catalog may refer to bundled resources.
            guard bundledModels().contains(where: { $0.file == model.file && $0.sha256 == model.sha256 && $0.bundledResource == resource }),
                  let url = bundle.url(forResource: resource, withExtension: nil) else {
                throw InstallationError.missingResource
            }
            source = url
        } else {
            guard let url = URL(string: model.file, relativeTo: Self.modelListUrl) else { throw InstallationError.invalidFile }
            let downloadURL = fileName.hasSuffix(".mlpackage") ? url.appendingPathExtension("zip") : url
            let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? fm.removeItem(at: temporary)
                throw InstallationError.invalidResponse
            }
            source = staging.appendingPathComponent("download")
            try fm.moveItem(at: temporary, to: source)
        }
        if let expected = model.sha256 {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw InstallationError.invalidChecksum }
        }
        if fileName.hasSuffix(".mlpackage") {
            try fm.unzipItem(at: source, to: stagedModel)
        } else {
            try fm.copyItem(at: source, to: stagedModel)
        }
        try Task.checkCancellation()
        // Compilation catches broken/incompatible packages before installation is committed.
        let compiled = try MLModel.compileModel(at: stagedModel)
        defer { try? fm.removeItem(at: compiled) }
        let mlModel = try MLModel(contentsOf: compiled)
        guard makeModel(mlModel, info: model) != nil else { throw InstallationError.invalidModel }
        var metadata = model
        metadata.file = fileName
        metadata.size = nil
        let metadataData = try JSONEncoder().encode(metadata)
        let destination = root.appendingPathComponent(fileName)
        // The UI only offers uninstalled models; never destroy an existing valid installation.
        guard !fm.fileExists(atPath: destination.path) else { return }
        try metadataData.write(to: root.appendingPathComponent(fileName + ".json"), options: .atomic)
        do {
            try fm.moveItem(at: stagedModel, to: destination)
        } catch {
            try? fm.removeItem(at: root.appendingPathComponent(fileName + ".json"))
            throw error
        }
        let compiledDestination = root.appendingPathComponent(fileName + ".mlmodelc")
        try? fm.removeItem(at: compiledDestination)
        try? fm.copyItem(at: compiled, to: compiledDestination)
        imageModelCache[fileName] = nil
    }

    func removeModel(withFile modelFile: String) {
        let name = (modelFile as NSString).lastPathComponent
        guard !installing.contains(name) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".mlmodelc"))
        imageModelCache[name] = nil
        if getEnabledModelFileName() == name { setEnabledModel(fileName: nil) }
    }

    func getInstalledModels() async -> [ModelInfo] {
        guard let root = try? modelsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return files.sorted().compactMap { file in
            guard ["mlpackage", "mlmodel"].contains((file as NSString).pathExtension),
                  let data = try? Data(contentsOf: root.appendingPathComponent(file + ".json")),
                  var info = try? JSONDecoder().decode(ModelInfo.self, from: data) else { return nil }
            info.file = file
            let url = root.appendingPathComponent(file)
            if file.hasSuffix(".mlpackage"), let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) {
                info.size = enumerator.compactMap { $0 as? URL }.reduce(0) { total, url in
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    return total + (values?.isRegularFile == true ? values?.fileSize ?? 0 : 0)
                }
            } else {
                info.size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            }
            return info
        }
    }

    func getAvailableModels(includeRemote: Bool = true) async -> [ModelInfo]? {
        var all = bundledModels()
        if includeRemote, let remote = try? await fetchModelList() {
            let bundledFiles = Set(all.map(\.file))
            all += remote.models.filter { !bundledFiles.contains(($0.file as NSString).lastPathComponent) && $0.bundledResource == nil }
        }
        guard let root = try? modelsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        let installed = Set(files)
        return all.filter {
            ($0.miniOS ?? 0) <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion
                && Self.supportedModelTypes.contains($0.type ?? "")
                && !installed.contains(($0.file as NSString).lastPathComponent)
        }
    }

    nonisolated func setEnabledModel(fileName: String?) {
        UserDefaults.standard.set(fileName, forKey: "Data.enabledModelFile")
    }

    nonisolated func getEnabledModelFileName() -> String? {
        UserDefaults.standard.string(forKey: "Data.enabledModelFile")
    }

    func getEnabledModel() throws -> ImageProcessingModel? {
        guard let name = getEnabledModelFileName() else { return nil }
        return try getModel(fileName: name)
    }

    func getModel(fileName: String) throws -> ImageProcessingModel? {
        let name = (fileName as NSString).lastPathComponent
        if let cached = imageModelCache[name] { return cached }
        // Release previous weights before compiling/loading a different model.
        imageModelCache.removeAll()
        let root = try modelsDirectory()
        let data = try Data(contentsOf: root.appendingPathComponent(name + ".json"))
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        let compiled = root.appendingPathComponent(name + ".mlmodelc")
        let mlModel: MLModel
        do {
            mlModel = try MLModel(contentsOf: compiled)
        } catch {
            // Core ML may invalidate compiled artifacts after an OS upgrade.
            let temporary = try MLModel.compileModel(at: root.appendingPathComponent(name))
            defer { try? FileManager.default.removeItem(at: temporary) }
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.copyItem(at: temporary, to: compiled)
            mlModel = try MLModel(contentsOf: compiled)
        }
        let model = makeModel(mlModel, info: info)
        if let model { imageModelCache[name] = model }
        return model
    }

    private func makeModel(_ model: MLModel, info: ModelInfo) -> ImageProcessingModel? {
        let config = info.config?.compactMapValues { $0.toRaw() } ?? [:]
        switch info.type?.lowercased() {
            case "multiarray": return MultiArrayModel(model: model, config: config)
            case "image": return ImageModel(model: model, config: config)
            default: return nil
        }
    }

    private func modelsDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fetchModelList() async throws -> ModelList {
        if let cachedModelList { return cachedModelList }
        var request = URLRequest(url: Self.modelListUrl)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallationError.invalidResponse
        }
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        cachedModelList = list
        return list
    }
}
