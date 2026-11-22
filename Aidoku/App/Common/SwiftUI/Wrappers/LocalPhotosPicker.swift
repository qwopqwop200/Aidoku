import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Copies selected photos to a private staging directory before provider URLs expire.
struct LocalPhotosPicker: UIViewControllerRepresentable {
    var onSelection: () -> Void
    var onCompletion: (URL?, [URL]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: LocalPhotosPicker

        init(parent: LocalPhotosPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            parent.onSelection()
            Task {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var urls = [URL?](repeating: nil, count: results.count)
                    // Loads are disk-backed (iCloud photos download first), so a few can overlap; order is kept by index.
                    try await withThrowingTaskGroup(of: (Int, URL).self) { group in
                        for (index, result) in results.enumerated() {
                            if index >= 4, let (done, url) = try await group.next() { urls[done] = url }
                            group.addTask {
                                let url: URL = try await withCheckedThrowingContinuation { continuation in
                                    result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                                        guard let url else {
                                            continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                                            return
                                        }
                                        do {
                                            let destination = directory.appendingPathComponent("\(index).\(url.pathExtension)")
                                            try FileManager.default.copyItem(at: url, to: destination)
                                            continuation.resume(returning: destination)
                                        } catch {
                                            continuation.resume(throwing: error)
                                        }
                                    }
                                }
                                return (index, url)
                            }
                        }
                        for try await (done, url) in group { urls[done] = url }
                    }
                    parent.onCompletion(directory, urls.compactMap { $0 })
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    parent.onCompletion(nil, [])
                }
            }
        }
    }
}
