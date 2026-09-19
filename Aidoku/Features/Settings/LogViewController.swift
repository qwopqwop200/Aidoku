//
//  LogViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 5/24/22.
//

import UIKit

class LogViewController: UIViewController {
    private let textView = UITextView()
    private var entries: [LogEntry] = []

    private var logTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("LOGS")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("CLEAR"),
            style: .plain,
            target: self,
            action: #selector(clearLog)
        )

        textView.attributedText = NSAttributedString(string: "")
        textView.font = UIFont(name: "Menlo", size: 12)
        textView.textColor = .label
        textView.isEditable = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        textView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        textView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        textView.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        textView.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true

    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard logTask == nil else { return }
        logTask = Task { [weak self] in
            let store = LogManager.logger.store
            let (entries, stream) = await store.snapshotAndStream()
            guard !Task.isCancelled else { return }
            self?.entries = entries
            self?.loadLog()
            for await entry in stream {
                guard !Task.isCancelled else { break }
                self?.entries.append(entry)
                if let self, self.entries.count > LogStore.maximumEntries {
                    self.entries.removeFirst(max(self.entries.count - LogStore.maximumEntries, LogStore.maximumEntries / 10))
                    self.loadLog()
                } else {
                    self?.logEntry(entry: entry)
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        logTask?.cancel()
        logTask = nil
    }

    deinit { logTask?.cancel() }

    func loadLog() {
        textView.attributedText = NSMutableAttributedString()
        entries.forEach { logEntry(entry: $0) }
    }

    @MainActor
    func logEntry(entry: LogEntry) {
        let string = NSMutableAttributedString()
        do {
            switch entry.type {
                case .default:
                    break
                case .info:
                    string.append(NSAttributedString(string: "[INFO] ", attributes: [.foregroundColor: UIColor.systemBlue]))
                case .debug:
                    string.append(NSAttributedString(string: "[DEBUG] ", attributes: [.foregroundColor: UIColor.label]))
                case .warning:
                    string.append(NSAttributedString(string: "[WARN] ", attributes: [.foregroundColor: UIColor.systemYellow]))
                case .error:
                    string.append(NSAttributedString(string: "[ERROR] ", attributes: [.foregroundColor: UIColor.systemRed]))
            }
            string.append(NSAttributedString(string: entry.message + "\n", attributes: [.foregroundColor: UIColor.label]))
            string.addAttributes([.font: UIFont(name: "Menlo", size: 12) as Any], range: NSRange(location: 0, length: string.length))
            textView.textStorage.append(string)
        }
    }

    @objc func clearLog() {
        entries = []
        textView.attributedText = NSMutableAttributedString()
        Task {
            await LogManager.logger.store.clear()
        }
    }
}
