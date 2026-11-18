//
//  BackupContentView.swift
//  Aidoku
//
//  Created by Skitty on 9/28/25.
//

import SwiftUI

struct BackupContentView: View {
    let backup: BackupInfo

    @State private var showRestoreAlert = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlatformNavigationStack {
            List {
                Section {
                    infoCell(title: NSLocalizedString("NAME"), value: backup.name ?? NSLocalizedString("NONE"))
                    infoCell(
                        title: NSLocalizedString("DATE"),
                        value: backup.date.formatted(date: .numeric, time: .shortened)
                    )
                }
                Section {
                    infoCell(
                        title: NSLocalizedString("LIBRARY_ENTRIES"),
                        value: String(backup.counts.library)
                    )
                    infoCell(
                        title: NSLocalizedString("HISTORY"),
                        value: String(backup.counts.history)
                    )
                    infoCell(
                        title: NSLocalizedString("CHAPTERS"),
                        value: String(backup.counts.chapters)
                    )
                    infoCell(
                        title: NSLocalizedString("TRACKING"),
                        value: String(backup.counts.trackItems)
                    )
                    infoCell(
                        title: NSLocalizedString("CATEGORIES"),
                        value: String(backup.counts.categories)
                    )
                    infoCell(
                        title: NSLocalizedString("VOCABULARY"),
                        value: String(backup.counts.vocabulary)
                    )
                    infoCell(
                        title: NSLocalizedString("SETTINGS"),
                        value: String(backup.counts.settings)
                    )
                }

                Section {
                    LargeButton {
                        showRestoreAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "gearshape.arrow.trianglehead.2.clockwise.rotate.90")
                            Text(NSLocalizedString("RESTORE"))
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("BACKUP_INFO_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton {
                        dismiss()
                    }
                }
            }
            .alert(NSLocalizedString("RESTORE_BACKUP"), isPresented: $showRestoreAlert) {
                Button(NSLocalizedString("CANCEL"), role: .cancel) {}
                Button(NSLocalizedString("RESTORE"), role: .destructive) {
                    Task { await BackupManager.shared.restore(from: backup.url) }
                }
            } message: {
                Text(NSLocalizedString("RESTORE_BACKUP_TEXT"))
            }
        }
    }

    func infoCell(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .lineLimit(1)
            Spacer()
            Text(value)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}
