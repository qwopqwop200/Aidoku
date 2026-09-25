//
//  SourceListsView.swift
//  Aidoku
//
//  Created by Skitty on 6/5/25.
//

import SwiftUI

struct SourceListsView: View {
    @State private var sourceListsURLs: [URL] = []
    @State private var sourceLists: [URL: SourceList] = [:]
    @State private var missingSourceLists: Set<URL> = []
    @State private var showAddListFailAlert = false
    @State private var listRefresh = SettingsRefreshScheduler()
    @State private var addTask: Task<Void, Never>?
    @State private var isAdding = false
    @State private var showAddProgress = false
    @State private var addGeneration = UUID()

    private var activeSourceListURLs: [URL] {
        sourceListsURLs.filter {
            !missingSourceLists.contains($0)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(activeSourceListURLs, id: \.self) { url in
                    if let sourceList = sourceLists[url] {
                        listItem(name: sourceList.name, url: sourceList.url)
                    } else {
                        listItem(url: url, loading: true)
                    }
                }
                .onDelete(perform: delete)
            }

            if !missingSourceLists.isEmpty {
                Section {
                    ForEach(sourceListsURLs, id: \.self) { url in
                        if missingSourceLists.contains(url) {
                            listItem(url: url)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("UNAVAILABLE_SOURCE_LISTS"))
                } footer: {
                    Text(NSLocalizedString("UNAVAILABLE_SOURCE_LISTS_TEXT"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("SOURCE_LISTS"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAlert()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isAdding)
            }
        }
        .alert(NSLocalizedString("SOURCE_LIST_ADD_FAIL"), isPresented: $showAddListFailAlert) {
            Button(NSLocalizedString("OK"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("SOURCE_LIST_ADD_FAIL_TEXT"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateSourceLists)) { _ in
            refreshSourceLists()
        }
        .task { refreshSourceLists() }
        .onDisappear {
            listRefresh.cancel()
            addGeneration = UUID()
            addTask?.cancel()
            addTask = nil
            isAdding = false
            showAddProgress = false
        }
        .overlay {
            if showAddProgress { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }

    private func refreshSourceLists() {
        listRefresh.request(operation: { await loadSourceLists() }, commit: { _ in })
    }

    func loadSourceLists() async {
        let urls = await SourceManager.shared.getSourceListURLs().sorted { $0.absoluteString < $1.absoluteString }
        guard !Task.isCancelled else { return }
        sourceListsURLs = urls

        let finished = await SourceManager.shared.sourceListLoadFinished
        guard !Task.isCancelled else { return }
        if finished {
            let missing = await SourceManager.shared.getMissingSourceLists()
            let loaded = await SourceManager.shared.getLoadedSourceLists()
            guard !Task.isCancelled else { return }
            missingSourceLists = missing
            sourceLists = loaded
        } else {
            missingSourceLists = []
            sourceLists = [:]

            let stream = await SourceManager.shared.streamSourceListsLoad()
            for await url in stream {
                let sourceList = await SourceManager.shared.getSourceList(url: url)
                guard !Task.isCancelled else { return }
                withAnimation {
                    sourceLists[url] = sourceList
                }
            }

            let newMissingSourceLists = await SourceManager.shared.getMissingSourceLists()
            guard !Task.isCancelled else { return }
            withAnimation {
                missingSourceLists = newMissingSourceLists
            }
        }
    }

    func listItem(name: String? = nil, url: URL, loading: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading) {
                if let name {
                    Text(name)
                }
                Text(url.absoluteString)
                    .lineLimit(1)
                    .font(.subheadline)
                    .foregroundStyle(name == nil ? .primary : .secondary)
            }
            if loading {
                ProgressView().progressViewStyle(.circular)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                sourceListsURLs.firstIndex(of: url).flatMap {
                    _ = sourceListsURLs.remove(at: $0)
                }
                sourceLists.removeValue(forKey: url)
                missingSourceLists.remove(url)
                Task {
                    await SourceManager.shared.removeSourceList(url: url)
                }
            } label: {
                Label(NSLocalizedString("REMOVE"), systemImage: "trash")
            }
            Button {
                UIPasteboard.general.string = url.absoluteString
            } label: {
                Label(NSLocalizedString("COPY_URL"), systemImage: "doc.on.doc")
            }
        }
    }

    func delete(at offsets: IndexSet) {
        let activeURLs = activeSourceListURLs
        let deleteURLs = offsets.map { activeURLs[$0] }
        Task {
            for url in deleteURLs {
                await SourceManager.shared.removeSourceList(url: url)
            }
        }
    }

    func addSourceList(url: String) {
        guard !url.isEmpty else { return }
        guard let url = URL(string: url) else {
            showAddListFailAlert = true
            return
        }

        guard !isAdding else { return }
        isAdding = true
        let generation = UUID()
        addGeneration = generation
        addTask = Task {
            let indicator = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, addGeneration == generation else { return }
                showAddProgress = true
            }
            defer {
                indicator.cancel()
                if addGeneration == generation {
                    isAdding = false
                    showAddProgress = false
                    addTask = nil
                }
            }
            let success = await SourceManager.shared.addSourceList(url: url)
            guard !Task.isCancelled, addGeneration == generation else { return }
            if success { refreshSourceLists() }
            else { showAddListFailAlert = true }
        }
    }

    func showAlert() {
        var alertTextField: UITextField?
        UIApplication.shared.appDelegate?.presentAlert(
            title: NSLocalizedString("SOURCE_LIST_ADD"),
            message: NSLocalizedString("SOURCE_LIST_ADD_TEXT"),
            actions: [
                UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel),
                UIAlertAction(title: NSLocalizedString("OK"), style: .default) { _ in
                    guard let text = alertTextField?.text, !text.isEmpty else { return }
                    addSourceList(url: text)
                }
            ],
            textFieldHandlers: [
                { textField in
                    textField.placeholder = NSLocalizedString("SOURCE_LIST_URL")
                    textField.keyboardType = .URL
                    textField.autocorrectionType = .no
                    textField.autocapitalizationType = .none
                    textField.returnKeyType = .done
                    alertTextField = textField
                }
            ]
        )
    }
}

#Preview {
    SourceListsView()
}
