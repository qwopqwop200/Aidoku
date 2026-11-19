import UIKit

@MainActor
enum ReaderTranslationImageExporter {
    enum ExportError: Error { case unavailable, renderFailed }

    static func saveAction(page: ReaderTranslationPage?, presenter: UIViewController) -> UIAction {
        UIAction(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"), image: UIImage(systemName: "character.bubble"),
                 attributes: page?.canExportTranslation == true ? [] : [.disabled]) { [weak page, weak presenter] _ in
            guard let page, let presenter else { return }
            Task { @MainActor in
                let progress = UIAlertController(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"),
                    message: NSLocalizedString("LOADING_ELLIPSIS"), preferredStyle: .alert)
                presenter.present(progress, animated: true)
                do {
                    let image = try await page.exportTranslatedImage(host: presenter.view)
                    progress.dismiss(animated: true) { image.saveToAlbum(viewController: presenter) }
                } catch {
                    progress.dismiss(animated: true) {
                        let alert = UIAlertController(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"),
                            message: NSLocalizedString("TRANSLATED_IMAGE_SAVE_FAILED"), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
                        presenter.present(alert, animated: true)
                    }
                }
            }
        }
    }
}
