import SwiftUI

@available(iOS 17.0, *)
struct HTTPSBypassSettingsView: View {
    @AppStorage(SourceNetwork.enabledKey) private var enabled = false
    @State private var address = "https://www.cloudflare.com"
    @State private var checking = false
    @State private var result: String?
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("HTTPS_BYPASS"), isOn: $enabled)
            } footer: {
                Text(NSLocalizedString("HTTPS_BYPASS_HELP"))
            }
            Section {
                TextField("https://example.com", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    check()
                } label: {
                    HStack {
                        Text(NSLocalizedString("HTTPS_BYPASS_TEST"))
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(checking)
                if let result { Text(result).font(.footnote).textSelection(.enabled) }
            } footer: {
                Text(NSLocalizedString("HTTPS_BYPASS_TEST_HELP"))
            }
        }
        .navigationTitle(NSLocalizedString("HTTPS_BYPASS"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: enabled) { _, _ in
            Task { @MainActor in
                do { try await SourceNetwork.refreshWebStores() } catch { result = NSLocalizedString("HTTPS_BYPASS_TEST_FAILED") }
            }
        }
        .onDisappear { testTask?.cancel() }
    }

    private func check() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            result = NSLocalizedString("HTTPS_BYPASS_INVALID_URL")
            return
        }
        checking = true
        result = nil
        testTask = Task { @MainActor in
            defer { checking = false }
            do {
                let response = try await SourceNetwork.shared.test(url: url)
                result = String(format: NSLocalizedString(response.fragmented ? "HTTPS_BYPASS_TEST_RESULT" : "HTTPS_BYPASS_TEST_UNCONFIRMED"),
                                response.status)
            } catch {
                result = NSLocalizedString("HTTPS_BYPASS_TEST_FAILED") + "\n" + error.localizedDescription
            }
        }
    }
}
