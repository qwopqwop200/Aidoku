import Foundation

struct SourceListCatalog {
    enum LoadState {
        case loading
        case loaded(SourceList)
        case unavailable
    }

    var states: [URL: LoadState] = [:] {
        didSet { installedMatches = nil }
    }
    private var installedMatches: (ids: Set<String>, sources: [String: ExternalSourceInfo])?

    /// Cache only the entries needed to annotate installed sources.
    mutating func latestSources(for ids: Set<String>) -> [String: ExternalSourceInfo] {
        guard !ids.isEmpty else {
            installedMatches = nil
            return [:]
        }
        if let installedMatches, installedMatches.ids == ids { return installedMatches.sources }

        var latest: [String: ExternalSourceInfo] = [:]
        for state in states.values {
            guard case let .loaded(list) = state else { continue }
            for source in list.sources where ids.contains(source.id) {
                if let previous = latest[source.id], previous.version >= source.version { continue }
                latest[source.id] = source
            }
        }
        installedMatches = (ids, latest)
        return latest
    }
}
