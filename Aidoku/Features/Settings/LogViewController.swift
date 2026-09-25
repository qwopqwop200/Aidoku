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
    private(set) var clearTask: Task<Void, Never>?
    private var isViewing = false
    private var flushTask: Task<Void, Never>?
    private var pendingEntries: [LogEntry] = []
    private var needsReload = false
    private let store: LogStore

    init(store: LogStore = LogManager.logger.store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.store = LogManager.logger.store
        super.init(coder: coder)
    }

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
        isViewing = true
        startObserving()
    }

    private func startObserving() {
        guard logTask == nil else { return }
        let store = store
        let pendingClear = clearTask
        logTask = Task { [weak self] in
            await pendingClear?.value
            guard !Task.isCancelled else { return }
            let (entries, stream) = await store.snapshotAndStream()
            guard !Task.isCancelled else { return }
            self?.entries = entries
            self?.loadLog()
            for await entry in stream {
                guard !Task.isCancelled else { break }
                self?.enqueue(entry: entry)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isViewing = false
        logTask?.cancel()
        logTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingEntries.removeAll()
        needsReload = false
    }

    deinit {
        logTask?.cancel()
        flushTask?.cancel()
    }

    func loadLog() {
        textView.attributedText = formatted(entries)
    }

    @MainActor
    func logEntry(entry: LogEntry) {
        textView.textStorage.append(formatted([entry]))
    }

    private func formatted(_ entries: [LogEntry]) -> NSAttributedString {
        let string = NSMutableAttributedString()
        for entry in entries {
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
        }
        string.addAttributes([.font: UIFont(name: "Menlo", size: 12) as Any], range: NSRange(location: 0, length: string.length))
        return string
    }

    // Keep one bounded pending batch and one timer, regardless of producer rate.
    func enqueue(entry: LogEntry) {
        entries.append(entry)
        if entries.count > LogStore.maximumEntries {
            entries.removeFirst(max(entries.count - LogStore.maximumEntries, LogStore.maximumEntries / 10))
            pendingEntries.removeAll()
            needsReload = true
        } else if !needsReload {
            pendingEntries.append(entry)
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingEntries()
        }
    }

    private func flushPendingEntries() {
        flushTask = nil
        if needsReload {
            loadLog()
        } else if !pendingEntries.isEmpty {
            textView.textStorage.append(formatted(pendingEntries))
        }
        pendingEntries.removeAll()
        needsReload = false
    }

    @objc func clearLog() {
        logTask?.cancel()
        logTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingEntries.removeAll()
        needsReload = false
        entries = []
        textView.attributedText = NSMutableAttributedString()
        let store = store
        let previousClear = clearTask
        clearTask = Task {
            await previousClear?.value
            await store.clear()
        }
        if isViewing { startObserving() }
    }
}
