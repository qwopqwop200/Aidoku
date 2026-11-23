//
//  AppDelegate.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 12/29/21.
//

import AidokuRunner
import CloudKit
import Nuke
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
#if CANONICAL_BUILD          // true only for App-Store scheme
    static let canonicalID = "app.aidoku.Aidoku"
#else
    static let canonicalID = Bundle.main.bundleIdentifier ?? ""
#endif

    static let isSideloaded = Bundle.main.bundleIdentifier != canonicalID

    private lazy var sourceStartup = Task { await SourceManager.shared.start() }
    private var networkObserverId: UUID?
    private var importingSharedImages = false
    private var sharedImageImportRequested = false

    private lazy var loadingAlert: UIAlertController = {
        let loadingAlert = UIAlertController(
            title: nil,
            message: NSLocalizedString("LOADING_ELLIPSIS"),
            preferredStyle: .alert
        )
        progressView.tintColor = loadingAlert.view.tintColor
        loadingAlert.view.addSubview(progressView)
        loadingAlert.view.addSubview(loadingIndicator)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        let progressViewSidePadding: CGFloat
        let progressViewBottomPadding: CGFloat
        let indicatorViewSidePadding: CGFloat
        if #available(iOS 26.0, *) {
            progressViewSidePadding = 32
            progressViewBottomPadding = 16
            indicatorViewSidePadding = 16
        } else {
            progressViewSidePadding = 16
            progressViewBottomPadding = 8
            indicatorViewSidePadding = 10
        }

        NSLayoutConstraint.activate([
            progressView.centerXAnchor.constraint(equalTo: loadingAlert.view.centerXAnchor),
            progressView.bottomAnchor.constraint(equalTo: loadingAlert.view.bottomAnchor, constant: -progressViewBottomPadding),
            progressView.widthAnchor.constraint(equalTo: loadingAlert.view.widthAnchor, constant: -(progressViewSidePadding * 2)),

            loadingIndicator.centerYAnchor.constraint(equalTo: loadingAlert.view.centerYAnchor),
            loadingIndicator.leadingAnchor.constraint(equalTo: loadingAlert.view.leadingAnchor, constant: indicatorViewSidePadding),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 50),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 50)
        ])
        return loadingAlert
    }()

    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let loadingIndicator = UIActivityIndicatorView(frame: .zero)
        loadingIndicator.style = .medium
        loadingIndicator.tag = 3
        return loadingIndicator
    }()

    private lazy var progressView: UIProgressView = {
        let progressView = UIProgressView(frame: .zero)
        progressView.progress = 0
        return progressView
    }()

    var indicatorProgress: Float {
        get { progressView.progress }
        set { progressView.progress = newValue }
    }

    var navigationController: UINavigationController? {
        (UIApplication.shared.firstKeyWindow?.rootViewController as? UITabBarController)?
            .selectedViewController as? UINavigationController
    }

    var visibleViewController: UIViewController? {
        ((UIApplication.shared.firstKeyWindow?.rootViewController as? UITabBarController)?
            .selectedViewController as? UINavigationController)?
            .visibleViewController
    }

    var topViewController: UIViewController? {
        if var topController = UIApplication.shared.firstKeyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            return topController
        } else {
            return nil
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UserDefaults.standard.register(
            defaults: [
                "History.lockHistoryTab": false,

                "Reader.readingMode": "auto",
                "Reader.skipDuplicateChapters": true,
                "Reader.markDuplicateChapters": true,
                "Reader.downsampleImages": false,
                "Reader.upscaleImages": false,
                "Reader.upscaleMaxHeight": 2000,
                "Reader.cropBorders": false,
                "Reader.disableQuickActions": false,
                "Reader.disableDoubleTap": false,
                "Reader.liveText": false,
                "Reader.hideBarsOnSwipe": false,
                "Reader.tapZones": "disabled",
                "Reader.invertTapZones": false,
                "Reader.animatePageTransitions": true,
                "Reader.backgroundColor": "black",
                "Reader.pagesToPreload": 2,
                "Reader.pagedPageLayout": "auto",
                "Reader.pagedPageOffset": false,
                "Reader.splitWideImages": false,
                "Reader.reverseSplitOrder": false,
                "Reader.verticalInfiniteScroll": true,
                "Reader.pillarbox": false,
                "Reader.pillarboxAmount": 15,
                "Reader.pillarboxOrientation": "both",
                "Reader.autoScroll": false,
                "Reader.autoScrollSpeed": 5,
                "Reader.orientation": "device",

                "Reader.textReaderStyle": "scroll",
                "Reader.textFontFamily": "System",
                "Reader.textFontSize": 18,
                "Reader.textLineSpacing": 8,
                "Reader.textHorizontalPadding": 24,
                "Reader.textTheme": "default",
                "Reader.textAppearance": "system"
            ]
        )
        AppSettings.registerDefaults()
        // Idempotent cleanup of the retired legacy page pipeline's cache rows, OCR tiers and keys.
        ReaderTranslationSettings.retiredKeys.forEach(UserDefaults.standard.removeObject(forKey:))
        Task(priority: .background) {
            try? await ReaderTranslationDiskCache.shared.purgeLegacyPipelineRows()
            try? await ReaderTranslationDiskCache.shared.compact()
        }
        Task.detached(priority: .utility) { NativeCoreMLModelStore.shared.reclaimLegacyExecutionCache() }

        // PlayCover fix: eagerly initialize the Core Data stack on the main thread
        // before any background migration task touches it. The `lazy var container`
        // and the singleton's init are not thread-safe; under PlayCover's timing the
        // main thread and a background migration task race to initialize them, and the
        // persistent-history remote-change observer's performAndWait deadlocks the
        // launch (no window ever appears). Forcing first init on the main thread here
        // makes the main thread win the race deterministically.
        _ = CoreDataManager.shared

        // check for icloud availability
        // https://developer.apple.com/documentation/foundation/filemanager/url(forubiquitycontaineridentifier:)
        // Do not call this method from your app’s main thread. Because this method might take a nontrivial amount of
        // time to set up iCloud and return the requested URL, you should always call it from a secondary thread.
        Task.detached {
            let isiCloudAvailable = FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
            if !isiCloudAvailable {
                LogManager.logger.info("iCloud unavailable")
            }
            AppSettings.flags.isiCloudAvailable.register(isiCloudAvailable)
        }

        DataLoader.sharedUrlCache.diskCapacity = 0

        let pipeline = ImagePipeline(delegate: self) {
            let dataLoader = SourceImageDataLoader()
            let dataCache = try? DataCache(name: "app.aidoku.Aidoku.datacache") // disk cache
            let imageCache = Nuke.ImageCache() // memory cache
            dataCache?.sizeLimit = 500 * 1024 * 1024
            imageCache.costLimit = 100 * 1024 * 1024
            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = dataLoader
            $0.dataCachePolicy = .storeOriginalData
            $0.isStoringPreviewsInMemoryCache = false
        }

        ImagePipeline.shared = pipeline

        performMigration()
        handleChaptersToBeDeleted()

        application.applicationSupportsShakeToEdit = true

        BackupManager.shared.register()
        MangaManager.shared.register()

        Self.removePreviousReaderSessions(in: [ReaderTemporaryPageStore.sessionsDirectory, TemporarySharedImageSession.root])

        // read before sceneDidBecomeActive can start a refresh that sets the flag again
        let refreshInterrupted = AppSettings.flags.libraryRefreshInProgress.get()
        Task {
            await sourceStartup.value
            await BackupManager.shared.scheduleAutoBackup()
            if #available(iOS 18.0, *) {
                DictionaryManager.shared.autoUpdateDictionaries()
            }

            networkObserverId = await Reachability.shared.registerConnectionTypeObserver { connectionType in
                Task {
                    await DownloadManager.shared.setWifiAvailable(connectionType == .wifi)
                }
            }

            if refreshInterrupted {
                presentAlert(
                    title: NSLocalizedString("LIBRARY_REFRESH_INTERRUPTED"),
                    message: NSLocalizedString("LIBRARY_REFRESH_INTERRUPTED_TEXT"),
                    actions: [
                        .init(title: NSLocalizedString("CANCEL"), style: .cancel) { _ in
                            AppSettings.flags.libraryRefreshInProgress.reset()
                        },
                        .init(title: NSLocalizedString("RESUME"), style: .default) { _ in
                            AppSettings.flags.libraryRefreshInProgress.reset()
                            Task {
                                await MangaManager.shared.refreshLibrary()
                            }
                        }
                    ]
                )
            } else {
                await MangaManager.shared.scheduleLibraryRefresh()
            }
        }

        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNotifyNewChaptersToggle(_:)),
            name: Notification.Name(AppSettings.library.notifyNewChapters.key),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLibraryUpdateIntervalChange(_:)),
            name: .init(AppSettings.library.updateInterval.key),
            object: nil
        )

        return true
    }

    @objc private func handleLibraryUpdateIntervalChange(_: Notification) {
        Task { await MangaManager.shared.scheduleLibraryRefresh() }
    }

    @objc private func handleNotifyNewChaptersToggle(_ note: Notification) {
        let enabled = (note.object as? Bool) ?? AppSettings.library.notifyNewChapters.get()
        guard enabled else { return }
        Task {
            let granted = await NotificationManager.shared.requestAuthorization()
            if !granted {
                await MainActor.run {
                    guard AppSettings.library.notifyNewChapters.get() else { return }
                    AppSettings.library.notifyNewChapters.set(false)
                    NotificationCenter.default.post(
                        name: .init(AppSettings.library.notifyNewChapters.key),
                        object: false
                    )
                }
            }
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        ImagePipeline.shared.configuration.imageCache?.removeAll()
        if #available(iOS 18.0, *) { Task { await ReaderTranslationPipelineService.shared.clearMemory() } }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        guard let networkObserverId else { return }
        Task {
            await Reachability.shared.unregisterConnectionTypeObserver(networkObserverId)
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        InterfaceOrientationCoordinator.shared.supportedOrientations
    }
}

extension AppDelegate {
    /// Capture the old session IDs before a newly opened reader can create its directory.
    @discardableResult
    nonisolated static func removePreviousReaderSessions(in roots: [URL]) -> Task<Void, Never>? {
        let fileManager = FileManager.default
        let oldSessions = roots.flatMap { root -> [URL] in
            guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                try? fileManager.removeItem(at: root)
                return []
            }
            return (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        }
        guard !oldSessions.isEmpty else { return nil }
        return Task.detached(priority: .utility) {
            for session in oldSessions { try? fileManager.removeItem(at: session) }
        }
    }

    func performMigration() {
        var settingsVersion = AppSettings.flags.currentVersion.get()
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        if let oldSettingsVersion = UserDefaults.standard.string(forKey: "currentVersion") {
            settingsVersion = settingsVersion ?? oldSettingsVersion
            UserDefaults.standard.removeObject(forKey: "currentVersion")
        }

        guard currentVersion != settingsVersion else {
            return
        }

        LogManager.logger.info("Migrating settings from version \(settingsVersion ?? "none") to \(currentVersion ?? "unknown")")

        // migrate history to 0.6 format
        if settingsVersion == "0.5" {
            Task.detached {
                await self.migrateHistory()
            }
        }

        // migration for 0.8.2
        if SourceManager.oldDirectory.exists {
            Task.detached {
                await self.migrateSources()
            }
        }

        migrateSettings()

        AppSettings.flags.currentVersion.set(currentVersion)
    }

    static nonisolated let legacySettingKeys: Set<String> = [
        "Browse.showNsfwSources",
        "Library.pinManga",
        // this is used for checking old backup settings, which won't restore unprefixed settings
//        "downloadChapterSortAscending",
//        "enabledModelFile",
//        "downloadQueueState",
//        "chaptersToBeDeleted",
        "General.portraitRows",
        "General.landscapeRows"
    ]

    func migrateSettings() {
        // migrate showNsfwSources setting
        if UserDefaults.standard.bool(forKey: "Browse.showNsfwSources") {
            AppSettings.browse.contentRatings.set([.safe, .containsNsfw, .primarilyNsfw])
            UserDefaults.standard.removeObject(forKey: "Browse.showNsfwSources")
        }

        // migrate pin settings
        if UserDefaults.standard.bool(forKey: "Library.pinManga") {
            let newValue = switch UserDefaults.standard.integer(forKey: "Library.pinMangaType") {
                case 0: LibraryViewModel.PinType.unread.rawValue
                case 1: LibraryViewModel.PinType.updatedChapters.rawValue
                default: LibraryViewModel.PinType.none.rawValue
            }
            AppSettings.library.pinTitles.set(newValue)
            UserDefaults.standard.removeObject(forKey: "Library.pinManga")
            UserDefaults.standard.removeObject(forKey: "Library.pinMangaType")
        }

        // migrate unprefixed settings
        if UserDefaults.standard.bool(forKey: "downloadChapterSortAscending") {
            AppSettings.flags.downloadChapterSortAscending.set(true)
            UserDefaults.standard.removeObject(forKey: "downloadChapterSortAscending")
        }
        if let enabledModelFile = UserDefaults.standard.string(forKey: "enabledModelFile") {
            UserDefaults.standard.set(enabledModelFile, forKey: "Data.enabledModelFile")
            UserDefaults.standard.removeObject(forKey: "enabledModelFile")
        }
        if let downloadQueueState = UserDefaults.standard.data(forKey: "downloadQueueState") {
            UserDefaults.standard.set(downloadQueueState, forKey: "Data.downloadQueueState")
            UserDefaults.standard.removeObject(forKey: "downloadQueueState")
        }
        if let chaptersToBeDeleted = UserDefaults.standard.data(forKey: "chaptersToBeDeleted") {
            UserDefaults.standard.set(chaptersToBeDeleted, forKey: "Data.chaptersToBeDeleted")
            UserDefaults.standard.removeObject(forKey: "chaptersToBeDeleted")
        }

        // migrate to layout appearance setting
        let portraitRows = UserDefaults.standard.integer(forKey: "General.portraitRows")
        let landscapeRows = UserDefaults.standard.integer(forKey: "General.landscapeRows")
        let defaultPortraitRows = UIDevice.current.userInterfaceIdiom == .pad ? 5 : 2
        let defaultLandscapeRows = UIDevice.current.userInterfaceIdiom == .pad ? 6 : 4
        if portraitRows > 0 && portraitRows != defaultPortraitRows {
            AppSettings.appearance.layout.set(.custom)
            AppSettings.appearance.customPortraitRows.set(portraitRows)
            UserDefaults.standard.removeObject(forKey: "General.portraitRows")
        }
        if landscapeRows > 0 && landscapeRows != defaultLandscapeRows {
            AppSettings.appearance.layout.set(.custom)
            AppSettings.appearance.customLandscapeRows.set(landscapeRows)
            UserDefaults.standard.removeObject(forKey: "General.landscapeRows")
        }
    }

    private func migrateHistory() async {
        showLoadingIndicator(style: .progress)
        try? await Task.sleep(nanoseconds: 500 * 1_000_000)
        await CoreDataManager.shared.migrateChapterHistory(progress: { @Sendable progress in
            Task { @MainActor in
                self.indicatorProgress = progress
            }
        })
        NotificationCenter.default.post(name: .updateLibrary, object: nil)
        await hideLoadingIndicator()
    }

    // migration for 0.8.2
    private func migrateSources() async {
        showLoadingIndicator(style: .indefinite)

        try? await Task.sleep(nanoseconds: 500 * 1_000_000)

        // migrate tracker token settings
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("Token.") {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.set(value, forKey: key.replacingOccurrences(of: "Token.", with: "Tracker."))
        }

        // handle lastUpdatedChapters addition
        await CoreDataManager.shared.container.performBackgroundTask { context in
            let items = CoreDataManager.shared.getLibraryManga(context: context)
            // if lastUpdatedChapters is set to the default value, update default to lastUpdated
            for item in items where item.lastUpdatedChapters.timeIntervalSince1970 == 21600 {
                item.lastUpdatedChapters = item.lastUpdated
            }
            do { try context.save() } catch {
                LogManager.logger.error("Failed to persist migrated chapter update dates: \(error)")
            }
        }

        // move all sources in old sources directory to the new one
        FileManager.default.moveFiles(in: SourceManager.oldDirectory, to: SourceManager.directory)
        // Failed moves (for example insufficient storage or duplicate names) remain recoverable.
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: SourceManager.oldDirectory.path), remaining.isEmpty {
            SourceManager.oldDirectory.removeItem()
        }
        await SourceManager.shared.reloadSources()

        await hideLoadingIndicator()
    }

    // delete chapters queued for deletion in last launch
    func handleChaptersToBeDeleted() {
        guard
            let data = UserDefaults.standard.data(forKey: "Data.chaptersToBeDeleted"),
            let chapterKeys = try? JSONDecoder().decode([ChapterIdentifier].self, from: data)
        else {
            return
        }
        Task {
            await DownloadManager.shared.delete(chapters: chapterKeys.map {
                .init(sourceKey: $0.sourceKey, mangaKey: $0.mangaKey, chapterKey: $0.chapterKey)
            })
            UserDefaults.standard.removeObject(forKey: "Data.chaptersToBeDeleted")
        }
    }

    enum LoadingStyle {
        case indefinite
        case progress
    }

    /// Shows a non-interactive loading indicator.
    func showLoadingIndicator(
        style: LoadingStyle = .indefinite,
        message: String = NSLocalizedString("LOADING_ELLIPSIS"),
        completion: (() -> Void)? = nil
    ) {
        loadingAlert.message = message
        switch style {
            case .indefinite:
                loadingIndicator.startAnimating()
                loadingIndicator.isHidden = false
                progressView.isHidden = true
            case .progress:
                progressView.progress = 0
                loadingIndicator.isHidden = true
                progressView.isHidden = false
        }
        topViewController?.present(loadingAlert, animated: true, completion: completion)
    }

    /// Updates the  progress of a shown loading indicator.
    func updateLoadingIndicator(progress: Float) {
        progressView.progress = progress
    }

    /// Dismisses a shown loading indicator.
    func hideLoadingIndicator() async {
        // A dismiss issued mid-presentation is dropped by UIKit without calling its completion.
        if loadingAlert.isBeingPresented, let coordinator = loadingAlert.transitionCoordinator {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var resumed = false
                let resume = { if !resumed { resumed = true; continuation.resume() } }
                if !coordinator.animate(alongsideTransition: nil, completion: { _ in resume() }) { resume() }
            }
        }
        // The alert is not shown when another controller was already presenting; nothing to wait for.
        guard loadingAlert.presentingViewController != nil else {
            loadingIndicator.stopAnimating()
            return
        }
        await withCheckedContinuation { continuation in
            loadingAlert.dismiss(animated: true) {
                self.loadingIndicator.stopAnimating()
                continuation.resume()
            }
        }
    }

    func handleUrl(url: URL) {
        if url.scheme == "aidoku" || url.scheme?.lowercased() ==
            (Bundle.main.object(forInfoDictionaryKey: "SHARED_IMAGE_URL_SCHEME") as? String)?.lowercased() {
            if url.host == "importSharedImages" {
                importPendingSharedImages()
            } else if url.host == "addSourceList" { // addSourceList?url=
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if
                    let listUrlString = components?.queryItems?.first(where: { $0.name == "url" })?.value,
                    let listUrl = URL(string: listUrlString)
                {
                    Task {
                        let sourceListURLs = await SourceManager.shared.getSourceListURLs()
                        guard !sourceListURLs.contains(listUrl) else { return }
                        let success = await SourceManager.shared.addSourceList(url: listUrl)
                        if success {
                            presentAlert(
                                title: NSLocalizedString("SOURCE_LIST_ADDED"),
                                message: NSLocalizedString("SOURCE_LIST_ADDED_TEXT")
                            )
                        } else {
                            presentAlert(
                                title: NSLocalizedString("SOURCE_LIST_ADD_FAIL"),
                                message: NSLocalizedString("SOURCE_LIST_ADD_FAIL_TEXT")
                            )
                        }
                    }
                }
            } else {
                // todo: we should support opening items in library even if the source isn't installed
                Task { @MainActor in
                    await sourceStartup.value
                    guard let host = url.host, let source = await SourceManager.shared.source(for: host) else {
                        // check for tracker auth callback
                        // this shouldn't really be called since authentication should be performed within the app
                        if let tracker = TrackerManager.trackers.first(where: {
                            ($0 as? OAuthTracker)?.callbackHost == url.host
                        }) as? OAuthTracker {
                            await tracker.handleAuthenticationCallback(url: url)
                        } else {
                            await handleDeepLink(url: url)
                        }
                        return
                    }
                    // support percent encoding characters like "/" for manga and chapter keys
                    let pathComponents = url.percentEncodedPath
                        .split(separator: "/")
                        .map { String($0).removingPercentEncoding ?? String($0) }

                    if !pathComponents.isEmpty { // /sourceId/mangaId
                        let mangaKey = pathComponents[0]
                        guard
                            let navigationController,
                            let manga = try? await source.getMangaUpdate(
                                manga: AidokuRunner.Manga(sourceKey: source.id, key: mangaKey, title: ""),
                                needsDetails: true,
                                needsChapters: false
                            )
                        else {
                            return
                        }
                        let chapterKey = pathComponents[safe: 1]
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let action = components?.queryItems?.first(where: { $0.name == "action" })?.value.flatMap(MangaView.OpenAction.init)

                        navigationController.pushViewController(
                            MangaViewController(
                                source: source,
                                manga: manga,
                                parent: navigationController.topViewController,
                                chapterKey: chapterKey, // /sourceId/mangaId/chapterId
                                openAction: action // ?action={read,readNext,readLatest}
                            ),
                            animated: true
                        )
                    } else { // /sourceId
                        let vc = NewSourceViewController(source: source)
                        navigationController?.pushViewController(vc, animated: true)
                    }
                }
            }
        } else if url.pathExtension == "aix" {
            Task {
                do {
                    let result = try await SourceManager.shared.importSourceValidated(from: url)
                    if result == nil {
                        presentAlert(title: NSLocalizedString("IMPORT_FAIL"), message: NSLocalizedString("SOURCE_IMPORT_FAIL_TEXT"))
                    }
                } catch {
                    presentAlert(title: NSLocalizedString("IMPORT_FAIL"), message: error.aidokuDescription())
                }
            }
        } else if url.pathExtension == "json" || url.pathExtension == "aib" {
            Task {
                if await BackupManager.shared.importBackup(from: url) {
                    presentAlert(
                        title: NSLocalizedString("BACKUP_IMPORT_SUCCESS"),
                        message: NSLocalizedString("BACKUP_IMPORT_SUCCESS_TEXT")
                    )
                } else {
                    presentAlert(
                        title: NSLocalizedString("IMPORT_FAIL"),
                        message: NSLocalizedString("BACKUP_IMPORT_FAIL_TEXT")
                    )
                }
            }
        } else if url.isFileURL && LocalFileManager.allowedFileExtensions.contains(url.pathExtension.lowercased()) {
            Task {
                do {
                    let manga = try await LocalFileManager.shared.importSharedArchive(from: url)
                    NotificationCenter.default.post(name: .init("refresh-content"), object: nil)
                    if let navigationController,
                       let source = await SourceManager.shared.source(for: LocalSourceRunner.sourceKey) {
                        navigationController.pushViewController(
                            MangaViewController(source: source, manga: manga, parent: navigationController.topViewController),
                            animated: true
                        )
                    }
                } catch {
                    LogManager.logger.error("Failed to import shared archive: \(error)")
                    presentAlert(title: NSLocalizedString("IMPORT_FAIL"), message: NSLocalizedString("FILE_IMPORT_FAIL_TEXT"))
                }
            }
        } else if url.isFileURL, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            Task {
                let fileInfo = await LocalFileManager.shared.loadImportFileInfo(url: url)
                if let fileInfo {
                    navigationController?.present(
                        UIHostingController(rootView: LocalFileImportView(fileInfo: fileInfo)),
                        animated: true
                    )
                } else {
                    presentAlert(
                        title: NSLocalizedString("IMPORT_FAIL"),
                        message: NSLocalizedString("FILE_IMPORT_FAIL_TEXT")
                    )
                }
            }
        } else {
            Task {
                await handleDeepLink(url: url)
            }
        }
    }

    func importPendingSharedImages(skipping handled: Set<URL> = []) {
        // A share that lands during an import is picked up when it finishes, not at the next activation.
        guard !importingSharedImages else { sharedImageImportRequested = true; return }
        guard let presenter = Self.sharedImagePresenter(in: UIApplication.shared.firstKeyWindow) else { return }
        importingSharedImages = true
        Task {
            var seen = handled
            defer {
                importingSharedImages = false
                if sharedImageImportRequested {
                    sharedImageImportRequested = false
                    importPendingSharedImages(skipping: seen)
                }
            }
            do {
                let inbox = try SharedImageInbox.live()
                let batches = try inbox.pendingBatches()
                // The URL open and scene activation both fire per share; rerun only for batches not seen yet.
                guard !batches.isEmpty, !Set(batches.map(\.directory)).isSubset(of: handled) else { return }
                seen.formUnion(batches.map(\.directory))
                if !AppSettings.reader.saveSharedImages.get() {
                    var readable = batches
                    var info = await LocalFileManager.shared.prepareImageImport(from: batches.flatMap(\.images), name: batches[0].title)
                    if info == nil {
                        // Find the bad batches so they cannot keep every other share from opening.
                        readable = []
                        for batch in batches {
                            if await LocalFileManager.shared.prepareImageImport(from: batch.images, name: batch.title) != nil {
                                readable.append(batch)
                            } else {
                                inbox.recordFailedAttempt(batch)
                            }
                        }
                        if let first = readable.first {
                            info = await LocalFileManager.shared.prepareImageImport(from: readable.flatMap(\.images), name: first.title)
                        }
                    }
                    guard let info else { throw LocalFileManagerError.invalidFileType }
                    let temporary = try TemporarySharedImageSession(fileInfo: info)
                    for batch in readable { try? inbox.remove(batch) }
                    Self.presentSharedImageController(ReaderNavigationController(readerViewController: ReaderViewController(
                        source: temporary.source, manga: temporary.manga, chapter: temporary.chapter,
                        startPage: 1, temporaryImageSession: temporary
                    )), from: presenter)
                    return
                }
                guard await SourceManager.shared.ensureLocalSourceForImport() else { return }
                var lastMangaID: String?
                var failedBatches = 0
                for batch in batches {
                    // A previous launch may have saved the chapter before removing the inbox item.
                    if await LocalFileDataManager.shared.hasChapter(series: batch.title.normalized, volume: nil, chapter: 1) {
                        lastMangaID = batch.title.normalized
                        try? inbox.remove(batch)
                        continue
                    }
                    // Keep a batch that cannot be imported for a bounded number of retries, but do
                    // not let it (or a failed save) block every newer share behind it.
                    do {
                        guard let info = await LocalFileManager.shared.prepareImageImport(
                            from: batch.images, name: batch.title
                        ) else { throw LocalFileManagerError.invalidFileType }
                        try await LocalFileManager.shared.uploadFile(
                            from: info.url,
                            mangaName: batch.title,
                            chapterName: batch.title,
                            chapter: 1
                        )
                    } catch {
                        failedBatches += 1
                        if inbox.recordFailedAttempt(batch) {
                            LogManager.logger.error("Discarded shared image batch after repeated failures: \(error)")
                        }
                        continue
                    }
                    lastMangaID = batch.title.normalized
                    // The saved chapter is detected on the next launch if this removal fails.
                    try? inbox.remove(batch)
                }
                NotificationCenter.default.post(name: .init("refresh-content"), object: nil)
                if let lastMangaID,
                   var manga = await LocalFileDataManager.shared.fetchLocalSeries(id: lastMangaID),
                   let source = await SourceManager.shared.source(for: LocalSourceRunner.sourceKey) {
                    manga.chapters = await LocalFileDataManager.shared.fetchChapters(mangaId: lastMangaID)
                    if let chapter = manga.chapters?.first {
                        let reader = ReaderViewController(source: source, manga: manga, chapter: chapter, startPage: 1)
                        Self.presentSharedImageController(ReaderNavigationController(readerViewController: reader), from: presenter)
                    }
                }
                if failedBatches > 0 {
                    // Alert only when nothing opened; an alert would race the reader presentation.
                    guard lastMangaID != nil else { throw LocalFileManagerError.invalidFileType }
                    LogManager.logger.error("Failed to prepare \(failedBatches) shared image batch(es)")
                }
            } catch SharedImageInbox.InboxError.unavailable {
                // Builds without an App Group can still use the in-app image picker.
            } catch {
                LogManager.logger.error("Failed to import shared images: \(error)")
                presentAlert(title: NSLocalizedString("IMPORT_FAIL"), message: NSLocalizedString("FILE_IMPORT_FAIL_TEXT"))
            }
        }
    }

    // The Settings tab is a SwiftUI hosting controller on iPhone, not a navigation controller.
    static func sharedImagePresenter(in window: UIWindow?) -> UIViewController? {
        guard let window, !window.isHidden, let root = window.rootViewController else { return nil }
        // Full-screen readers detach the root view from the window. Keep the root as the
        // presentation owner, but accept its visible modal chain when receiving another share.
        guard sequence(first: root, next: \.presentedViewController).contains(where: {
            $0.viewIfLoaded?.window === window
        }) else { return nil }
        return root
    }

    static func presentSharedImageController(_ controller: UIViewController, from presenter: UIViewController) {
        controller.modalPresentationStyle = .fullScreen
        let chain = presenter.presentedViewController.map { Array(sequence(first: $0, next: \.presentedViewController)) } ?? []
        // Close an open reader through its own close path. Dismissing a SwiftUI fullScreenCover from the root
        // leaves its binding set, so SwiftUI brings the old reader back over the shared image reader.
        guard let index = chain.firstIndex(where: { readerViewController(in: $0) != nil }),
              let reader = readerViewController(in: chain[index]) else {
            presentWhenIdle(controller, from: presenter)
            return
        }
        let closeReader = {
            reader.close(animated: false) {
                // Let SwiftUI clear the cover's state before presenting over the same root.
                DispatchQueue.main.async { presentWhenIdle(controller, from: presenter) }
            }
        }
        if index + 1 < chain.count {
            chain[index].dismiss(animated: false, completion: closeReader)
        } else {
            closeReader()
        }
    }

    private static func readerViewController(in controller: UIViewController) -> ReaderViewController? {
        if let reader = controller as? ReaderViewController { return reader }
        for child in controller.children {
            if let reader = readerViewController(in: child) { return reader }
        }
        return nil
    }

    private static func presentWhenIdle(_ controller: UIViewController, from presenter: UIViewController, attempts: Int = 0) {
        guard let presented = presenter.presentedViewController else {
            presenter.present(controller, animated: true)
            return
        }
        if presented.isBeingDismissed, attempts < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                presentWhenIdle(controller, from: presenter, attempts: attempts + 1)
            }
            return
        }
        presenter.dismiss(animated: false) { presenter.present(controller, animated: true) }
    }

    func handleDeepLink(url: URL) async -> Bool {
        guard
            let navigationController,
            let targetUrl = (url as NSURL).resourceSpecifier
        else { return false }

        let allSources = await SourceManager.shared.getLoadedSources()

        // find source that uses the given url
        var targetSource: AidokuRunner.Source?
        var finalUrl: String?
        for source in allSources {
            for sourceUrl in source.urls {
                if let url = (sourceUrl as NSURL).resourceSpecifier, targetUrl.hasPrefix(url) {
                    targetSource = source
                    finalUrl = "\(URL(string: url)?.scheme ?? "https"):\(targetUrl)"
                    break
                }
            }
            if targetSource != nil { break }
        }

        guard let targetSource, let finalUrl else { return false }

        let task = Task { @MainActor in
            do {
                let link = try await targetSource.handleDeepLink(url: finalUrl)

                if let mangaId = link?.mangaKey {
                    // open manga view and scroll to chapter if given
                    guard let manga = try? await targetSource.getMangaUpdate(
                        manga: AidokuRunner.Manga(
                            sourceKey: targetSource.id,
                            key: mangaId,
                            title: ""
                        ),
                        needsDetails: true,
                        needsChapters: false
                    ) else {
                        return false
                    }

                    navigationController.pushViewController(
                        MangaViewController(
                            source: targetSource,
                            manga: manga,
                            parent: navigationController.topViewController,
                            chapterKey: link?.chapterKey,
                            openAction: .read
                        ),
                        animated: true
                    )

                    return true
                } else if let listing = link?.listing {
                    // open source listing
                    let viewController = SourceListingViewController(source: targetSource, listing: listing)
                    navigationController.pushViewController(viewController, animated: true)

                    return true
                }
            } catch {
                LogManager.logger.error("Failed to handle source deep link: \(error.localizedDescription)")
            }

            return false
        }

        return await task.value
    }

    func handleSourceMigration(source: AidokuRunner.Source) {
        presentAlert(
            title: NSLocalizedString("SOURCE_BREAKING_CHANGE"),
            message: NSLocalizedString("SOURCE_BREAKING_CHANGE_TEXT"),
            actions: [
                .init(title: NSLocalizedString("MIGRATE"), style: .default) { _ in
                    if source.features.handlesMigration {
                        // if the source handles the migration, we can migrate all the db ids
                        self.showLoadingIndicator()
                        Task {
                            let (
                                libraryMangaIds,
                                libraryChaptersIds,
                                historyMangaIds,
                                historyChapterIds,
                            ) = await CoreDataManager.shared.container.performBackgroundTask { context in
                                let historyObjects = CoreDataManager.shared.getHistory(sourceKey: source.id, context: context)
                                return (
                                    CoreDataManager.shared.getLibraryManga(sourceKey: source.id, context: context)
                                        .compactMap { $0.manga?.id },
                                    CoreDataManager.shared.getChapters(sourceKey: source.id, context: context)
                                        .map { ($0.mangaId, $0.id) },
                                    historyObjects.map { $0.mangaId },
                                    historyObjects.map { ($0.mangaId, $0.chapterId) },
                                )
                            }
                            var newMangaIds: [String: String] = [:]
                            var newChapterIds: [ChapterIdentifier: String] = [:]
                            if source.features.handlesNotifications {
                                try? await source.handleNotification(notification: "system.startMigration")
                            }
                            for oldId in libraryMangaIds {
                                newMangaIds[oldId] = try? await source.handleMigration(kind: .manga, mangaKey: oldId, chapterKey: nil)
                            }
                            for oldId in historyMangaIds where newMangaIds[oldId] == nil  {
                                newMangaIds[oldId] = try? await source.handleMigration(kind: .manga, mangaKey: oldId, chapterKey: nil)
                            }
                            for (mangaId, oldId) in libraryChaptersIds {
                                newChapterIds[.init(sourceKey: source.id, mangaKey: mangaId, chapterKey: oldId)] = try? await source.handleMigration(kind: .chapter, mangaKey: mangaId, chapterKey: oldId)
                            }
                            if source.features.handlesNotifications {
                                try? await source.handleNotification(notification: "system.endMigration")
                            }
                            for (mangaId, oldId) in historyChapterIds where newChapterIds[.init(sourceKey: source.id, mangaKey: mangaId, chapterKey: oldId)] == nil  {
                                newChapterIds[.init(sourceKey: source.id, mangaKey: mangaId, chapterKey: oldId)] = try? await source.handleMigration(kind: .chapter, mangaKey: mangaId, chapterKey: oldId)
                            }
                            await CoreDataManager.shared.container.performBackgroundTask { [newMangaIds, newChapterIds] context in
                                let libraryObjects = CoreDataManager.shared.getLibraryManga(sourceKey: source.id, context: context)
                                let chapterObjects = CoreDataManager.shared.getChapters(sourceKey: source.id, context: context)
                                let historyObjects = CoreDataManager.shared.getHistory(sourceKey: source.id, context: context)
                                for object in libraryObjects {
                                    guard
                                        let oldId = object.manga?.id,
                                        let newId = newMangaIds[oldId]
                                    else { continue }
                                    object.manga?.id = newId
                                }
                                for object in chapterObjects {
                                    let oldKey = ChapterIdentifier(sourceKey: source.id, mangaKey: object.mangaId, chapterKey: object.id)
                                    object.mangaId = newMangaIds[object.mangaId] ?? object.mangaId
                                    object.id = newChapterIds[oldKey] ?? object.id
                                }
                                for object in historyObjects {
                                    let oldKey = ChapterIdentifier(sourceKey: source.id, mangaKey: object.mangaId, chapterKey: object.chapterId)
                                    object.mangaId = newMangaIds[object.mangaId] ?? object.mangaId
                                    object.chapterId = newChapterIds[oldKey] ?? object.chapterId
                                }
                                do {
                                    try context.save()
                                } catch {
                                    LogManager.logger.error("Failed to save id migration: \(error)")
                                }
                            }

                            NotificationCenter.default.post(name: .updateLibrary, object: nil)
                            NotificationCenter.default.post(name: .updateHistory, object: nil)

                            await self.hideLoadingIndicator()
                        }
                    } else {
                        // otherwise, we just show the migration view and let the user do it
                        Task {
                            let sourceManga = await CoreDataManager.shared.container.performBackgroundTask { context in
                                let objects = CoreDataManager.shared.getLibraryManga(sourceKey: source.id, context: context)
                                return objects.compactMap { $0.manga?.toNewManga() }
                            }
                            if !sourceManga.isEmpty {
                                let migrateView = MigrateResultsView(targetSources: [source], selectedSeries: sourceManga, forceMigrate: true)
                                let viewController = SwiftUINavigationViewController(rootView: migrateView, addDismissButton: false)
                                self.topViewController?.present(viewController, animated: true)
                            }
                        }
                    }
                }
            ]
        )
    }

    func presentAlert(
        title: String,
        message: String? = nil,
        actions: [UIAlertAction] = [],
        textFieldHandlers: [((UITextField) -> Void)] = [],
        textFieldDisablesLastActionWhenEmpty: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

        for handler in textFieldHandlers {
            alertController.addTextField { textField in
                handler(textField)

                if textFieldDisablesLastActionWhenEmpty && textFieldHandlers.count == 1 {
                    actions.last?.isEnabled = !(textField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                    let lastAction = actions.last
                    textField.addAction(UIAction { [weak textField, weak lastAction] _ in
                        let text = textField?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        lastAction?.isEnabled = !text.isEmpty
                    }, for: .editingChanged)
                }
            }
        }

        // if no actions are provided, add a default 'OK' action
        if actions.isEmpty {
            let okAction = UIAlertAction(title: NSLocalizedString("OK"), style: .cancel)
            alertController.addAction(okAction)
        } else {
            for action in actions {
                alertController.addAction(action)
            }
        }

        topViewController?.present(alertController, animated: true, completion: completion)
    }
}

extension AppDelegate: ImagePipeline.Delegate {
    nonisolated func imageDecoder(for context: ImageDecodingContext, pipeline: ImagePipeline) -> (any ImageDecoding)? {
        if context.request.userInfo[.processesKey] as? Bool == true {
            // when using a page processor, don't decode data as an image since it may be invalid
            ImageDecoders.Empty.init()
        } else {
            // Hard decode cap: an over-cap page is decoded through ImageIO's thumbnail
            // path even when reader downsampling is off, never at full resolution.
            pipeline.configuration.makeImageDecoder(ImagePixelCap.decodingContext(context))
        }
    }
}

extension AppDelegate: @MainActor UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        // C++ interop imports this callback's options as Int; match it so foreground notifications arrive.
        withCompletionHandler completionHandler: @escaping @Sendable (Int) -> Void
    ) {
        let options: UNNotificationPresentationOptions = [.banner, .sound, .list]
        completionHandler(Int(options.rawValue))
    }

    static func notificationURL(sourceId: String, mangaId: String) -> URL? {
        // The deep-link parser splits before decoding, so encode slashes in the manga key too.
        let componentCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let source = sourceId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let manga = mangaId.addingPercentEncoding(withAllowedCharacters: componentCharacters)
        else { return nil }
        return URL(string: "aidoku://\(source)/\(manga)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if
            let sourceId = userInfo[NotificationManager.sourceIdInfoKey] as? String,
            let mangaId = userInfo[NotificationManager.mangaIdInfoKey] as? String,
            let url = Self.notificationURL(sourceId: sourceId, mangaId: mangaId)
        {
            Task { @MainActor in
                self.handleUrl(url: url)
            }
        }
        completionHandler()
    }
}
