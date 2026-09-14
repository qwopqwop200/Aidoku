import SwiftUI

enum ReaderTranslationLanguageOptions {
    static let codes = AutomaticSourceLanguageDetector.supportedLanguageCodes.sorted {
        name($0).localizedStandardCompare(name($1)) == .orderedAscending
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code == "zh" ? "zh-Hans" : code) ?? code
    }
}

struct ReaderTranslationLanguageFilterView: View {
    @Binding var selection: [String]
    @State private var search = ""

    private var filteredCodes: [String] {
        ReaderTranslationLanguageOptions.codes.filter {
            search.isEmpty || $0.localizedStandardContains(search) ||
                ReaderTranslationLanguageOptions.name($0).localizedStandardContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                Button { selection = [] } label: {
                    row(NSLocalizedString("TRANSLATION_FILTER_ALL"), selected: selection.isEmpty)
                }
                .accessibilityIdentifier("translation.sourceFilter.all")
            } footer: {
                Text(NSLocalizedString("TRANSLATION_FILTER_HELP"))
            }
            Section {
                ForEach(filteredCodes, id: \.self) { code in
                    Button {
                        if selection.contains(code) { selection.removeAll { $0 == code } } else { selection.append(code) }
                    } label: {
                        row(ReaderTranslationLanguageOptions.name(code), code: code, selected: selection.contains(code))
                    }
                    .accessibilityIdentifier("translation.sourceFilter." + code)
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(NSLocalizedString("TRANSLATION_SOURCE_FILTER"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, code: String? = nil, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                if let code { Text(code).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
