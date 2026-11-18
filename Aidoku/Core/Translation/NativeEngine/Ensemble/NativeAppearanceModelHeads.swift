import CryptoKit
import Foundation

/// Source model lookup and accepted categorical/palette head decisions.
/// Learned estimators are immutable native numeric graphs, never Python.
final class NativeAppearanceModelHeads: @unchecked Sendable {
    enum Failure:Error {case missingAssets,invalidMetadata(String),invalidOutput(String)}
    let directory:URL
    let metadata:[String:Any]
    private let registry:NativeFrozenSourceModel.Registry
    private let entries:[String:[String:Any]]
    private var cache:[String:NativeFrozenSourceModel]=[:]
    private let lock=NSLock()
    private struct MetadataDocument:Decodable {
        struct Container:Decodable {let tree:[String:NativeFrozenSourceModel.Value]}
        let schema:Int
        let sourceOnly:Bool
        let GTAtInference:Bool
        let metadata:Container
    }

    init(directory:URL) throws {
        self.directory=directory
        let data=try Data(contentsOf:directory.appendingPathComponent("registry-index.json"))
        guard let document=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let entries=document["heads"] as? [String:[String:Any]],
              let metadataAssets=document["metadataAssets"] as? [String:[String:Any]],
              let appearance=metadataAssets["appearance"],let asset=appearance["asset"] as? String,
              let expected=appearance["sha256"] as? String,!asset.contains(".."),!asset.hasPrefix("/") else {
            throw Failure.invalidMetadata("complete appearance metadata tree")
        }
        let encoded=try Data(contentsOf:directory.appendingPathComponent(asset))
        guard SHA256.hash(data:encoded).map({String(format:"%02x",$0)}).joined()==expected else {
            throw Failure.invalidMetadata("changed appearance policy metadata")
        }
        let decoded=try JSONDecoder().decode(MetadataDocument.self,from:encoded)
        guard decoded.schema==1,decoded.sourceOnly,!decoded.GTAtInference else {throw Failure.invalidMetadata("appearance metadata provenance")}
        self.entries=entries;self.metadata=decoded.metadata.tree.mapValues(\.foundationValue)
        registry=try .init(directory:directory)
    }
    convenience init(bundle:Bundle = .main) throws {
        guard let resources=bundle.resourceURL else {throw Failure.missingAssets}
        let candidates=[resources.appendingPathComponent("Translation/SourceModels"),
            resources.appendingPathComponent("SourceModels"),resources.appendingPathComponent("Resources/Translation/SourceModels"),resources]
        guard let directory=candidates.first(where:{FileManager.default.fileExists(atPath:$0.appendingPathComponent("registry.json").path)}) else {
            throw Failure.missingAssets
        }
        try self.init(directory:directory)
    }

    func configuration(_ key:String) throws -> [String:Any] {
        guard let config=metadata[key] as? [String:Any] else {throw Failure.invalidMetadata(key)}
        return config
    }
    func model(_ key:String) throws -> NativeFrozenSourceModel {
        lock.lock();defer {lock.unlock()}
        if let model=cache[key] {return model}
        guard let entry=entries[key],let relative=entry["asset"] as? String,
              let expected=entry["sha256"] as? String,!relative.hasPrefix("/"),!relative.split(separator:"/").contains("..") else {
            throw Failure.invalidMetadata(key)
        }
        let data=try Data(contentsOf:directory.appendingPathComponent(relative))
        let actual=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
        guard actual==expected else {throw Failure.invalidMetadata("changed exported head "+key)}
        let result=try registry.model(key);cache[key]=result;return result
    }
    func positive(_ key:String,_ matrix:[[Float]]) throws -> [Double] {
        let model=try model(key)
        guard model.classes==[0,1] else {throw Failure.invalidMetadata("binary source classifier "+key)}
        return try matrix.map {row in
            let values=try model.predictProbability(row.map(Double.init))
            guard values.count==2,values.allSatisfy(\.isFinite) else {throw Failure.invalidOutput(key)}
            return values[1]
        }
    }
    static func number(_ config:[String:Any],_ key:String) throws -> Double {
        guard let number=config[key] as? NSNumber,number.doubleValue.isFinite else {throw Failure.invalidMetadata(key)}
        return number.doubleValue
    }
    private func rank(_ key:String,_ matrix:[[Float]],excluding:Int?=nil) throws -> Int {
        var scores=try positive(key,matrix)
        guard !scores.isEmpty else {throw Failure.invalidOutput(key)}
        if let excluding {scores[excluding] = -1}
        var chosen=0
        for index in scores.indices.dropFirst() where scores[index]>scores[chosen] {chosen=index}
        return chosen
    }

    func primary(_ packet:NativeAppearanceSourceFeatures209.Packet,
                 root:String="appearance/model",configuration:[String:Any]?=nil) throws -> [String:Any] {
        let config=try configuration ?? self.configuration(root)
        let fill=try rank(root+"/fill",packet.features)
        let outline=try rank(root+"/outline",packet.role("outline",fill:fill),excluding:fill)
        let conditioned=config["conditionedBackground"] as? Bool == true
        let background=try rank(root+"/background",packet.role("background",fill:conditioned ? fill:nil,outline:conditioned ? outline:nil))
        let summary=packet.summary(fill:fill,outline:outline,background:background)
        let outlineProbability=try positive(root+"/outlinePresence",[summary])[0]
        let shadowProbability=try positive(root+"/shadowPresence",[summary])[0]
        return ["fillIndex":fill,"outlineIndex":outline,"backgroundIndex":background,
            "fill":["rgb":packet.colors[fill]],
            "outline":["present":outlineProbability >= (try Self.number(config,"outlineThreshold")),"rgb":packet.colors[outline],
                "probability":outlineProbability,"widthPx":NSNull(),"widthRangePx":NSNull()],
            "background":["rgb":packet.colors[background]],
            "shadow":["present":shadowProbability >= (try Self.number(config,"shadowThreshold")),"probability":shadowProbability,
                "rgb":NSNull(),"offsetPx":NSNull(),"blurRadiusPx":NSNull(),"opacity":NSNull()],
            "inferenceUsesGT":false,"sourceOnly":true]
    }
}
