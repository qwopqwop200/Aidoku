import UIKit

final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let progress = UIActivityIndicatorView(style: .large)
    private let done = UIButton(type: .system)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Aidoku"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.textAlignment = .center
        status.text = NSLocalizedString("IMPORT", comment: "")
        status.font = .preferredFont(forTextStyle: .body)
        status.numberOfLines = 0
        status.textAlignment = .center
        done.setTitle(NSLocalizedString("DONE", comment: ""), for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        done.isHidden = true
        let stack = UIStackView(arrangedSubviews: [title, progress, status, done])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        progress.startAnimating()
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        Task {
            do {
                try await SharedImageInbox.live().enqueue(providers: providers)
                if await openContainingApp() {
                    finish()
                    return
                }
                status.text = NSLocalizedString("SHARED_IMAGES_SAVED", comment: "")
            } catch {
                let failure = error as NSError
                status.text = NSLocalizedString("SHARED_IMAGE_IMPORT_FAILED", comment: "")
                    + "\n(\(failure.domain): \(failure.code))"
            }
            progress.stopAnimating()
            done.isHidden = false
        }
    }

    private func openContainingApp() async -> Bool {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "SHARED_IMAGE_URL_SCHEME") as? String,
              let url = URL(string: "\(scheme)://importSharedImages") else { return false }
        // Share extensions do not have a guaranteed launch API. Prefer the extension
        // context, then use the responder application's modern URL API on supported OSes.
        // Keep the inbox intact if the OS refuses, so the selection is never lost.
        if let extensionContext {
            let opened = await withCheckedContinuation { continuation in
                extensionContext.open(url) { continuation.resume(returning: $0) }
            }
            if opened { return true }
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await withCheckedContinuation { continuation in
                    application.open(url, options: [:]) { continuation.resume(returning: $0) }
                }
            }
            responder = current.next
        }
        return false
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
