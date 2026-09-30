/// HTTP verbs shared by the native self-hosted source clients.
/// Keep the historical raw values so saved/request method identifiers retain their meaning.
enum HttpMethod: Int, Sendable {
    case GET = 0
    case POST = 1
    case HEAD = 2
    case PUT = 3
    case DELETE = 4
    case PATCH = 5
    case OPTIONS = 6
    case CONNECT = 7
    case TRACE = 8

    var stringValue: String {
        switch self {
            case .GET: "GET"
            case .POST: "POST"
            case .HEAD: "HEAD"
            case .PUT: "PUT"
            case .DELETE: "DELETE"
            case .PATCH: "PATCH"
            case .OPTIONS: "OPTIONS"
            case .CONNECT: "CONNECT"
            case .TRACE: "TRACE"
        }
    }
}
