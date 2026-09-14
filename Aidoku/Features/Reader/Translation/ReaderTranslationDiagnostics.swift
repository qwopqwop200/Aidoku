import os

/// Page positions and phase transitions only: never page text, URLs or credentials.
enum ReaderTranslationDiagnostics {
    private static let logger = os.Logger(subsystem: "app.aidoku.Aidoku", category: "ReaderPreparation")

    static func record(_ event: String, page: Int = -1, count: Int = 0, code: Int = 0) {
        logger.notice("""
        reader_event=\(event, privacy: .public) page=\(page, privacy: .public) \
        count=\(count, privacy: .public) code=\(code, privacy: .public)
        """)
    }
}
