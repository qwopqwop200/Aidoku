import Testing

@MainActor
@Suite(.serialized)
struct NativeSourceCanvasRealizationDiagnosticTests {
    @Test func publicImageRealizationRoutesPreserveSameSourceControls() async throws {
        try await NativeSourceCanvasRealizationDiagnosticCapture().run()
    }
}
