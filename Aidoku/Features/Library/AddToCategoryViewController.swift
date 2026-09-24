//
//  AddToCategoryViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 1/3/23.
//

import UIKit

class AddToCategoryViewController: BaseTableViewController {
    let manga: [MangaInfo]
    var disabledCategories: [String] // categories disabled for selection

    var categories: [String] = []
    var selectedCategories: [String] = [] // for multiselect

    private var isSaving = false

    var multiselect: Bool = false // if enabled, can select multiple

    lazy var dataSource = makeDataSource()

    override var tableViewStyle: UITableView.Style {
        .plain
    }

    init(manga: [MangaInfo], disabledCategories: [String] = []) {
        self.manga = manga
        self.disabledCategories = disabledCategories
        super.init()
    }

    override func configure() {
        super.configure()

        title = multiselect
            ? NSLocalizedString("ADD_TO_CATEGORIES")
            : NSLocalizedString("ADD_TO_CATEGORY")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(close)
        )
        if multiselect {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(done)
            )
        }

        tableView.dataSource = dataSource
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UITableViewCell")

        Task {
            categories = await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getCategoryTitles(context: context)
            }
            updateDataSource()
        }
    }

    @objc func close() {
        dismiss(animated: true)
    }

    @objc func done() {
        guard !isSaving else { return }
        isSaving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task {
            defer {
                isSaving = false
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            if await saveSelectedCategories() { close() }
        }
    }

    /// One selection is one transaction; failed saves cannot publish success.
    func saveSelectedCategories() async -> Bool {
        do {
            try await CoreDataManager.shared.container.performBackgroundTask { [selectedCategories, manga] context in
                for info in manga {
                    CoreDataManager.shared.addCategoriesToManga(
                        mangaId: info.id,
                        categories: selectedCategories,
                        context: context
                    )
                }
                do { try context.save() } catch { context.rollback(); throw error }
            }
            NotificationCenter.default.post(name: .updateMangaCategories, object: manga)
            return true
        } catch {
            LogManager.logger.error("AddToCategoryViewController.save: \(error.localizedDescription)")
            let alert = UIAlertController(title: NSLocalizedString("ERROR"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
            present(alert, animated: true)
            return false
        }
    }

}

// MARK: - Table View Delegate
extension AddToCategoryViewController {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let cell = tableView.cellForRow(at: indexPath), let category = dataSource.itemIdentifier(for: indexPath) {
            if disabledCategories.contains(category) {
                return
            }
            if multiselect {
                if cell.accessoryType == .checkmark {
                    cell.accessoryType = .none
                    selectedCategories.removeAll { $0 == category }
                } else {
                    cell.accessoryType = .checkmark
                    selectedCategories.append(category)
                }
            } else {
                selectedCategories.append(category)
                done()
            }
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

// MARK: - Data Source
extension AddToCategoryViewController {

    enum Section: Int {
        case regular
    }

    private func makeDataSource() -> UITableViewDiffableDataSource<Section, String> {
        UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, category in
            guard let self = self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(withIdentifier: "UITableViewCell", for: indexPath)
            cell.textLabel?.text = category
            if self.multiselect {
                if self.selectedCategories.contains(category) {
                    cell.accessoryType = .checkmark
                } else {
                    cell.accessoryType = .none
                }
            }
            cell.selectionStyle = .default
            cell.textLabel?.textColor = .label
            if self.disabledCategories.contains(category) {
                cell.selectionStyle = .none
                cell.textLabel?.textColor = .secondaryLabel
            }
            return cell
        }
    }

    func updateDataSource() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()

        snapshot.appendSections([.regular])
        snapshot.appendItems(categories)

        dataSource.apply(snapshot)
    }
}
