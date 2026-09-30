import Foundation

@main
struct AnalysisMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 else { fputs("Usage: analysis RUN_OR_IMAGE_DIRECTORY REPOSITORY_ROOT\n", stderr); exit(2) }
        do {
            try HostAnalysis.generateRun(URL(fileURLWithPath: args[0]).standardizedFileURL,
                root: URL(fileURLWithPath: args[1]).standardizedFileURL)
            print("Analysis: \(URL(fileURLWithPath: args[0]).appendingPathComponent("analysis-index.html").path)")
        } catch { fputs("Analysis: \(error)\n", stderr); exit(1) }
    }
}
