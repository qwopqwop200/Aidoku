import Foundation

@main enum NativeAppearanceForestSmoke {
    struct Request: Decodable { let head:String; let values:[Double] }
    static func main() throws {
        let bundle=try JSONDecoder().decode(NativeAppearanceForest.Bundle.self,
            from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        precondition(bundle.schema==1 && bundle.sourceOnly && !bundle.GTAtInference)
        let requests=try JSONDecoder().decode([Request].self,
            from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        let results=try requests.map { request in
            guard let head=bundle.heads[request.head] else {throw NativeAppearanceForest.Failure.invalidModel}
            return try head.predict(request.values)
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
