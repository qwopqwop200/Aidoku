import Foundation

@main
struct NativeFrozenSourceModelReplay {
    struct Request: Decodable {
        let id: String
        let rows: [[Double?]]
        let probability: Bool
        let trees: Bool
    }
    struct Response: Encodable {
        let id: String
        let values: [[Double]]
        let trees: [[[Double]]]
        let classes: [Double]
        let classGroups: [[Double]]
    }
    static func main() throws {
        let registry = try NativeFrozenSourceModel.Registry(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        if CommandLine.arguments[2].hasPrefix("--metadata") {
            let selected = try CommandLine.arguments[2] == "--metadata-eager"
                ? NativeFrozenSourceModel.Registry(directory: URL(fileURLWithPath: CommandLine.arguments[1]), includeMetadata: true)
                : registry
            let tree = try selected.metadataTreeFoundation
            guard let font = tree["font198"] as? [String: Any], let probe = font["probe"] as? Double else {
                throw NativeFrozenSourceModel.Failure.invalidModel
            }
            print(probe.bitPattern)
            return
        }
        let requests = try JSONDecoder().decode([Request].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        var replies: [Response] = []
        for request in requests {
            FileHandle.standardError.write(Data(("replay " + request.id + "\n").utf8))
            let rows = request.rows.map { $0.map { $0 ?? .nan } }
            let model = try registry.model(request.id)
            let result = try request.probability ? model.predictProbability(rows) : model.predict(rows)
            let trees = try request.trees ? rows.map { try model.predictTrees($0) } : []
            replies.append(Response(id: request.id, values: result, trees: trees,
                                    classes: model.classes, classGroups: model.classGroups))
        }
        try JSONEncoder().encode(replies).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
}
