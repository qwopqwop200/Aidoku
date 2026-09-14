import Combine
import UIKit

@MainActor
final class SearchSuggestionsViewController: UITableViewController {
    let viewModel: SearchSuggestionsViewModel
    var onSelect: ((SearchSuggestionQuery, SearchSuggestion) -> Void)?
    private var observation: AnyCancellable?
    private var entries: [SearchSuggestion] = []
    private var heightConstraint: NSLayoutConstraint?

    init(viewModel: SearchSuggestionsViewModel) {
        self.viewModel = viewModel
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .secondarySystemBackground
        tableView.keyboardDismissMode = .none
        tableView.register(SearchSuggestionCell.self, forCellReuseIdentifier: "suggestion")
        tableView.rowHeight = SearchSuggestionCell.rowHeight
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.accessibilityLabel = NSLocalizedString("SEARCH_SUGGESTIONS", comment: "")
        tableView.tableFooterView = UIView()
        observation = viewModel.$suggestions.sink { [weak self] entries in
            guard let self else { return }
            self.entries = entries
            self.tableView.reloadData()
            self.tableView.setContentOffset(.zero, animated: false)
            self.view.isHidden = entries.isEmpty
            self.heightConstraint?.constant = CGFloat(entries.count) * self.tableView.rowHeight
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        tableView.rowHeight = SearchSuggestionCell.rowHeight
        heightConstraint?.constant = CGFloat(entries.count) * tableView.rowHeight
        tableView.reloadData()
    }

    func attach(to parent: UIViewController) {
        parent.addChild(self)
        parent.view.addSubview(view)
        didMove(toParent: parent)
        view.translatesAutoresizingMaskIntoConstraints = false
        let height = view.heightAnchor.constraint(equalToConstant: 0)
        height.priority = .defaultHigh
        heightConstraint = height
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.topAnchor),
            view.leadingAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.trailingAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: parent.view.keyboardLayoutGuide.topAnchor),
            height
        ])
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "suggestion", for: indexPath) as? SearchSuggestionCell else {
            return UITableViewCell()
        }
        cell.configure(with: entries[indexPath.row], matching: viewModel.query?.term ?? "")
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard entries.indices.contains(indexPath.row), let query = viewModel.query else { return }
        let entry = entries[indexPath.row]
        viewModel.dismiss()
        onSelect?(query, entry)
    }
}
