import AppKit
import Combine
import Foundation
import WebKit

struct BrowserTabGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isCollapsed: Bool
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [BrowserTab]
    @Published private(set) var groups: [BrowserTabGroup]
    @Published var selectedID: UUID
    @Published var restoreTabs: Bool { didSet { preferences.set(restoreTabs, forKey: Keys.restoreTabs); saveSession() } }
    @Published var searchEngine: String { didSet { preferences.set(searchEngine, forKey: Keys.searchEngine) } }
    @Published var memorySaver: Bool { didSet { preferences.set(memorySaver, forKey: Keys.memorySaver) } }
    @Published var saveCredentials: Bool { didSet { preferences.set(saveCredentials, forKey: Keys.saveCredentials) } }
    @Published private(set) var isClearingData = false
    @Published var showingAgent = false
    lazy var agent = AgentController(model: self)
    @Published var showingSettings = false
    @Published var focusAddressToken = 0
    @Published private(set) var credentialStatus: String?

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    var canCreateGroup: Bool { groups.count < 32 }

    private enum Keys {
        static let storeID = "dev.leanbrowser.desktop.websiteDataStoreID"
        static let session = "dev.leanbrowser.desktop.session.v1"
        static let restoreTabs = "dev.leanbrowser.desktop.restoreTabs"
        static let searchEngine = "dev.leanbrowser.desktop.searchEngine"
        static let memorySaver = "dev.leanbrowser.desktop.memorySaver"
        static let saveCredentials = "dev.leanbrowser.desktop.saveCredentials"
    }

    private struct Session: Codable {
        let tabs: [TabMetadata]
        let selectedID: UUID?
        let groups: [BrowserTabGroup]

        init(tabs: [TabMetadata], selectedID: UUID?, groups: [BrowserTabGroup]) {
            self.tabs = tabs
            self.selectedID = selectedID
            self.groups = groups
        }

        private enum CodingKeys: String, CodingKey { case tabs, selectedID, groups }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tabs = try container.decode([TabMetadata].self, forKey: .tabs)
            selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID)
            groups = try container.decodeIfPresent([BrowserTabGroup].self, forKey: .groups) ?? []
        }
    }

    private enum NavigationInputError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value }
        }
    }

    fileprivate struct TabMetadata: Codable {
        let id: UUID
        let url: URL?
        let title: String
        let groupID: UUID?
    }

    private let preferences: UserDefaults
    let credentialStore = CredentialStore()
    fileprivate let websiteDataStore: WKWebsiteDataStore
    private var closedTabs: [TabMetadata] = []
    private var activeDownloads: [ObjectIdentifier: (download: WKDownload, tab: BrowserTab)] = [:]
    private var memoryTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        preferences = defaults
        let shouldRestoreTabs = defaults.object(forKey: Keys.restoreTabs) as? Bool ?? true
        restoreTabs = shouldRestoreTabs
        searchEngine = defaults.string(forKey: Keys.searchEngine) ?? "DuckDuckGo"
        memorySaver = defaults.object(forKey: Keys.memorySaver) as? Bool ?? true
        saveCredentials = defaults.object(forKey: Keys.saveCredentials) as? Bool ?? true

        let identifier: UUID
        if let saved = defaults.string(forKey: Keys.storeID), let parsed = UUID(uuidString: saved) {
            identifier = parsed
        } else {
            identifier = UUID()
            defaults.set(identifier.uuidString, forKey: Keys.storeID)
        }
        websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)

        let restored = shouldRestoreTabs ? Self.loadSession(from: defaults) : nil
        let restoredGroups = Array((restored?.groups ?? []).prefix(32))
        groups = restoredGroups
        let groupIDs = Set(restoredGroups.map(\.id))
        let metadata = Array((restored?.tabs ?? []).prefix(32)).map { metadata in
            guard let groupID = metadata.groupID, !groupIDs.contains(groupID) else { return metadata }
            return TabMetadata(id: metadata.id, url: metadata.url, title: metadata.title, groupID: nil)
        }
        if metadata.isEmpty {
            let tab = BrowserTab(metadata: TabMetadata(id: UUID(), url: nil, title: "", groupID: nil), model: nil)
            tabs = [tab]
            selectedID = tab.id
        } else {
            let restoredTabs = metadata.map { BrowserTab(metadata: $0, model: nil) }
            tabs = restoredTabs
            selectedID = restored?.selectedID.flatMap { id in restoredTabs.contains(where: { $0.id == id }) ? id : nil } ?? restoredTabs[0].id
        }
        tabs.forEach { $0.model = self }
        startMemoryTimer()
    }

    deinit { memoryTimer?.invalidate() }

    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true) -> BrowserTab? {
        guard !isClearingData, tabs.count < 32 else { return nil }
        selectedTab?.lastSelectedAt = Date()
        let tab = BrowserTab(metadata: TabMetadata(id: UUID(), url: nil, title: "", groupID: nil), model: self)
        tabs.append(tab)
        if select {
            selectedID = tab.id
            credentialStatus = nil
        }
        if let url { load(url, in: tab) }
        saveSession()
        return tab
    }

    func selectTab(_ id: UUID) {
        guard !isClearingData, let tab = tabs.first(where: { $0.id == id }) else { return }
        if let previous = selectedTab, previous.id != id { previous.lastSelectedAt = Date() }
        selectedID = id
        credentialStatus = nil
        tab.lastSelectedAt = Date()
        if tab.isSuspended { tab.resumeIfNeeded() }
        saveSession()
    }

    func closeTab(_ id: UUID) {
        guard !isClearingData, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        closedTabs.append(tab.metadata)
        if closedTabs.count > 32 { closedTabs.removeFirst(closedTabs.count - 32) }
        tab.discardWebView(force: true)
        if tabs.isEmpty {
            let home = BrowserTab(metadata: TabMetadata(id: UUID(), url: nil, title: "", groupID: nil), model: self)
            tabs = [home]
            selectedID = home.id
            credentialStatus = nil
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
            credentialStatus = nil
            selectedTab?.resumeIfNeeded()
        }
        saveSession()
    }

    func reopenClosedTab() {
        guard !isClearingData, tabs.count < 32, let metadata = closedTabs.popLast() else { return }
        selectedTab?.lastSelectedAt = Date()
        let validMetadata: TabMetadata
        if let groupID = metadata.groupID, !groups.contains(where: { $0.id == groupID }) {
            validMetadata = TabMetadata(id: metadata.id, url: metadata.url, title: metadata.title, groupID: nil)
        } else {
            validMetadata = metadata
        }
        let tab = BrowserTab(metadata: validMetadata, model: self)
        tabs.append(tab)
        selectedID = tab.id
        credentialStatus = nil
        tab.resumeIfNeeded()
        saveSession()
    }

    func navigate(_ input: String) {
        guard !isClearingData, let tab = selectedTab else { return }
        switch destination(for: input) {
        case .success(let url): load(url, in: tab)
        case .failure(let error): tab.errorMessage = error.localizedDescription
        }
    }

    func back() { guard !isClearingData, let tab = selectedTab, !tab.isHome else { return }; tab.resumeIfNeeded(); tab.webView.goBack() }
    func fillSavedCredential() {
        guard !isClearingData, let tab = selectedTab else { return }
        Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            let filled = await tab.fillSavedCredential()
            if !filled, self.selectedID == tab.id { self.credentialStatus = "저장된 로그인 정보를 입력할 수 없음" }
        }
    }

    func deleteSavedCredentials() {
        do {
            try credentialStore.deleteAll()
            credentialStatus = "저장된 로그인 정보 삭제됨"
        } catch {
            credentialStatus = "저장된 로그인 정보 삭제 안 됨"
        }
    }

    func noteCredentialSubmissionSaved() { credentialStatus = "제출한 로그인 정보 저장됨" }
    func noteCredentialSubmissionNotSaved() { credentialStatus = "제출한 로그인 정보 저장 안 됨" }
    func noteCredentialFilled() { credentialStatus = "저장된 로그인 정보 입력됨" }
    func forward() { guard !isClearingData, let tab = selectedTab, !tab.isHome else { return }; tab.resumeIfNeeded(); tab.webView.goForward() }
    func reloadOrStop() {
        guard !isClearingData, let tab = selectedTab else { return }
        guard !tab.isHome else { return }
        if tab.isLoading { tab.webViewIfLoaded?.stopLoading(); return }
        if tab.errorMessage != nil, let requestedURL = tab.lastRequestedURL ?? tab.url { load(requestedURL, in: tab); return }
        tab.resumeIfNeeded()
        tab.webView.reload()
    }
    func home() {
        guard !isClearingData, let tab = selectedTab else { return }
        tab.navigationGeneration += 1
        tab.discardWebView(force: true)
        tab.url = nil
        tab.title = ""
        tab.errorMessage = nil
        tab.isLoading = false
        tab.isSuspended = false
        tab.canGoBack = false
        tab.canGoForward = false
        tab.estimatedProgress = 0
        saveSession()
    }
    func focusAddress() { focusAddressToken += 1 }

    @discardableResult
    func createGroup(name: String) -> BrowserTabGroup? {
        guard canCreateGroup else { return nil }
        let group = BrowserTabGroup(id: UUID(), name: normalizedGroupName(name), isCollapsed: false)
        groups.append(group)
        saveSession()
        return group
    }

    func renameGroup(_ id: UUID, name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = normalizedGroupName(name)
        saveSession()
    }

    func deleteGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        objectWillChange.send()
        tabs.filter { $0.groupID == id }.forEach { $0.groupID = nil }
        closedTabs = closedTabs.map { metadata in
            guard metadata.groupID == id else { return metadata }
            return TabMetadata(id: metadata.id, url: metadata.url, title: metadata.title, groupID: nil)
        }
        groups.removeAll { $0.id == id }
        saveSession()
    }

    func assignTab(_ tabID: UUID, groupID: UUID?) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              groupID == nil || groups.contains(where: { $0.id == groupID }),
              tab.groupID != groupID else { return }
        objectWillChange.send()
        tab.groupID = groupID
        saveSession()
    }

    func moveTab(_ tabID: UUID, before destinationID: UUID?, groupID: UUID?) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }),
              destinationID != tabID,
              destinationID == nil || tabs.contains(where: { $0.id == destinationID && $0.groupID == groupID }),
              groupID == nil || groups.contains(where: { $0.id == groupID }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        objectWillChange.send()
        tab.groupID = groupID
        let insertionIndex: Int
        if let destinationID, let index = tabs.firstIndex(where: { $0.id == destinationID }) {
            insertionIndex = index
        } else if let groupID, let lastMember = tabs.lastIndex(where: { $0.groupID == groupID }) {
            insertionIndex = lastMember + 1
        } else {
            insertionIndex = tabs.count
        }
        tabs.insert(tab, at: insertionIndex)
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].isCollapsed = false
        }
        saveSession()
    }

    func setGroupCollapsed(_ id: UUID, collapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].isCollapsed != collapsed else { return }
        groups[index].isCollapsed = collapsed
        saveSession()
    }

    func clearBrowsingData() async {
        guard !isClearingData else { return }
        isClearingData = true
        agent.cancelAll()
        cancelActiveDownloads()
        closedTabs.removeAll()
        tabs.forEach {
            $0.url = nil
            $0.title = ""
            $0.errorMessage = nil
            $0.isLoading = false
            $0.isSuspended = false
            $0.lastRequestedURL = nil
            $0.canGoBack = false
            $0.canGoForward = false
            $0.estimatedProgress = 0
            $0.navigationGeneration += 1
            $0.discardWebView(force: true, preserveMetadata: false)
        }
        saveSession()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
        }
        isClearingData = false
    }

    func saveSession() {
        let session = Session(tabs: Array(tabs.prefix(32)).map(\.metadata), selectedID: selectedID, groups: groups)
        guard let data = try? JSONEncoder().encode(session) else { return }
        preferences.set(data, forKey: Keys.session)
    }

    func load(_ url: URL, in tab: BrowserTab) {
        guard !isClearingData else { return }
        tab.errorMessage = nil
        tab.isSuspended = false
        tab.navigationGeneration += 1
        tab.url = url
        tab.lastRequestedURL = url
        tab.isLoading = true
        if tab.webView.load(URLRequest(url: url)) == nil {
            tab.isLoading = false
            tab.errorMessage = "페이지를 열 수 없습니다."
        }
        saveSession()
    }

    fileprivate func createPopup(configuration: WKWebViewConfiguration, request: URLRequest?) -> WKWebView? {
        guard !isClearingData, tabs.count < 32 else { return nil }
        selectedTab?.lastSelectedAt = Date()
        let tab = BrowserTab(metadata: TabMetadata(id: UUID(), url: nil, title: "", groupID: nil), model: self, suppliedConfiguration: configuration)
        tabs.append(tab)
        selectedID = tab.id
        tab.url = request?.url
        tab.lastRequestedURL = request?.url
        let webView = tab.webView
        saveSession()
        return webView
    }

    private func destination(for raw: String) -> Result<URL, NavigationInputError> {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .failure(.message("주소 또는 검색어를 입력하세요.")) }
        if !input.contains(where: { $0.isWhitespace }),
           let components = URLComponents(string: "https://\(input)"),
           let host = components.host, components.port != nil,
           (host == "localhost" || host.contains(".")) {
            let scheme = (host == "localhost" || host == "127.0.0.1" || host == "::1") ? "http" : "https"
            return URL(string: "\(scheme)://\(input)").map(Result.success) ?? .failure(.message("올바른 주소가 아닙니다."))
        }
        if let components = URLComponents(string: input), let scheme = components.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else { return .failure(.message("http 또는 https 주소만 열 수 있습니다.")) }
            return components.url.map(Result.success) ?? .failure(.message("올바른 주소가 아닙니다."))
        }
        if !input.contains(where: { $0.isWhitespace }), input.contains("."),
           let url = URL(string: "https://\(input)") { return .success(url) }
        var components = URLComponents(string: searchEngine == "Google" ? "https://www.google.com/search" : "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url.map(Result.success) ?? .failure(.message("검색 주소를 만들 수 없습니다."))
    }

    private static func loadSession(from defaults: UserDefaults) -> Session? {
        guard let data = defaults.data(forKey: Keys.session) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func normalizedGroupName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "새 그룹" : trimmed).prefix(80))
    }

    private func startMemoryTimer() {
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.discardInactiveTabsIfSafe() }
        }
    }

    private func discardInactiveTabsIfSafe() {
        guard !isClearingData, memorySaver, tabs.filter({ $0.webViewIfLoaded != nil }).count > 3 else { return }
        let threshold = Date().addingTimeInterval(-120)
        for tab in tabs where tab.agentLeaseCount == 0 && tab.id != selectedID && tab.webViewIfLoaded != nil && !tab.isLoading && !tab.isSuspended && tab.lastSelectedAt < threshold {
            let generation = tab.navigationGeneration
            let tabID = tab.id
            let view = tab.webViewIfLoaded
            tab.isSafeToSuspend { [weak self, weak tab, weak view] safe in
                guard let self, let tab, safe,
                      self.memorySaver,
                      tab.agentLeaseCount == 0,
                      self.tabs.contains(where: { $0 === tab }),
                      self.selectedID != tabID,
                      tab.id == tabID,
                      tab.navigationGeneration == generation,
                      tab.webViewIfLoaded === view,
                      !tab.isLoading,
                      tab.lastSelectedAt < Date().addingTimeInterval(-120),
                      self.tabs.filter({ $0.webViewIfLoaded != nil }).count > 3 else { return }
                tab.discardWebView(force: false)
                self.saveSession()
            }
        }
    }

    fileprivate func webViewDidClose(_ webView: WKWebView) {
        guard !isClearingData, let tab = tabs.first(where: { $0.webViewIfLoaded === webView }) else { return }
        closeTab(tab.id)
    }

    fileprivate func beginDownload(_ download: WKDownload, from tab: BrowserTab) {
        guard !isClearingData else { download.cancel(nil); return }
        activeDownloads[ObjectIdentifier(download)] = (download, tab)
    }

    fileprivate func finishDownload(_ download: WKDownload) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
    }

    private func cancelActiveDownloads() {
        let downloads = activeDownloads.values.map(\.download)
        activeDownloads.removeAll()
        downloads.forEach { $0.cancel(nil) }
    }
}

@MainActor
final class BrowserTab: NSObject, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var url: URL?
    @Published var groupID: UUID?
    @Published var isLoading = false
    @Published var estimatedProgress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorMessage: String?
    @Published var isSuspended = false
    var isHome: Bool { url == nil }

    weak var model: BrowserModel?
    fileprivate var lastSelectedAt = Date()
    var agentLeaseCount = 0
    var navigationGeneration = 0
    fileprivate var lastRequestedURL: URL?
    fileprivate var metadata: BrowserModel.TabMetadata { .init(id: id, url: url, title: title, groupID: groupID) }
    var webViewIfLoaded: WKWebView? { storedWebView }
    private var storedWebView: WKWebView?
    private var suppliedConfiguration: WKWebViewConfiguration?
    private var observations: [NSKeyValueObservation] = []
    private var credentialBridge: CredentialBridge?

    var webView: WKWebView {
        if let storedWebView { return storedWebView }
        guard let model else { fatalError("BrowserTab requires BrowserModel before WebView creation") }
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = model.websiteDataStore
        let contentController = configuration.userContentController
        contentController.addUserScript(WKUserScript(source: Self.activityScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        let bridge = CredentialBridge(tab: self)
        bridge.install(on: view)
        suppliedConfiguration = nil
        view.navigationDelegate = self
        view.uiDelegate = self
        let resumeURL = isSuspended ? url : nil
        storedWebView = view
        credentialBridge = bridge
        installObservers(on: view)
        if let resumeURL {
            isSuspended = false
            navigationGeneration += 1
            lastRequestedURL = resumeURL
            url = resumeURL
            isLoading = true
            if view.load(URLRequest(url: resumeURL)) == nil {
                isLoading = false
                errorMessage = "페이지를 열 수 없습니다."
            }
        }
        return view
    }

    fileprivate init(metadata: BrowserModel.TabMetadata, model: BrowserModel?, suppliedConfiguration: WKWebViewConfiguration? = nil) {
        id = metadata.id
        url = metadata.url
        title = metadata.title
        groupID = metadata.groupID
        self.model = model
        self.suppliedConfiguration = suppliedConfiguration
        lastRequestedURL = metadata.url
        isSuspended = metadata.url != nil
        super.init()
    }

    func resumeIfNeeded() {
        lastSelectedAt = Date()
        guard model?.isClearingData != true, isSuspended else { return }
        _ = webView
    }

    fileprivate func discardWebView(force: Bool, preserveMetadata: Bool = true) {
        guard let view = storedWebView else { return }
        guard force || (agentLeaseCount == 0 && !isLoading && id != model?.selectedID) else { return }
        if preserveMetadata {
            url = view.url ?? url
            title = view.title ?? title
        }
        navigationGeneration += 1
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        view.stopLoading()
        credentialBridge?.uninstall(from: view)
        credentialBridge = nil
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        storedWebView = nil
        isLoading = false
        isSuspended = url != nil
    }

    func fillSavedCredential() async -> Bool {
        await credentialBridge?.fillSavedCredential() ?? false
    }

    fileprivate func isSafeToSuspend(completion: @escaping (Bool) -> Void) {
        guard let view = storedWebView else { completion(false); return }
        view.evaluateJavaScript("window.__leanBrowserActivity ? window.__leanBrowserActivity() : {dirty:true,media:true,editable:true}") { result, error in
            guard error == nil, let state = result as? [String: Any] else { completion(false); return }
            completion(!(state["dirty"] as? Bool ?? true) && !(state["media"] as? Bool ?? true) && !(state["editable"] as? Bool ?? true) && !(state["framed"] as? Bool ?? true))
        }
    }

    private func installObservers(on view: WKWebView) {
        observations = [
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.storedWebView === view else { return }
                    let title = view.title ?? ""
                    guard self.title != title else { return }
                    self.title = title
                    self.model?.saveSession()
                }
            },
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.storedWebView === view else { return }
                    let url = view.url ?? self.url
                    guard self.url != url else { return }
                    self.url = url
                    self.lastRequestedURL = url
                    self.model?.saveSession()
                }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.storedWebView === view else { return }
                    self.isLoading = view.isLoading
                }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.storedWebView === view else { return }
                    self.estimatedProgress = view.estimatedProgress
                }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.storedWebView === view else { return }
                    self.canGoBack = view.canGoBack
                }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.storedWebView === view else { return }
                    self.canGoForward = view.canGoForward
                }
            }
        ]
    }

    private static let activityScript = """
    (() => { let dirty = () => { window.__leanDirty = true; }; document.addEventListener('input', dirty, true); document.addEventListener('change', dirty, true); window.__leanBrowserActivity = () => ({dirty: !!window.__leanDirty, media: Array.from(document.querySelectorAll('audio,video')).some((element) => !element.paused && !element.ended), editable: !!(document.activeElement && (document.activeElement.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName))), framed: !!document.querySelector('iframe,frame')}); })();
    """
}

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { navigationGeneration += 1; errorMessage = nil; model?.saveSession() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { errorMessage = nil; model?.saveSession() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { record(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { record(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { errorMessage = "웹 콘텐츠 프로세스가 종료되었습니다. 다시 시도해 주세요." }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        model?.beginDownload(download, from: self)
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        model?.beginDownload(download, from: self)
        download.delegate = self
    }

    private func record(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        errorMessage = nsError.localizedDescription
    }
}

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        model?.createPopup(configuration: configuration, request: navigationAction.request)
    }

    func webViewDidClose(_ webView: WKWebView) {
        model?.webViewDidClose(webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { completionHandler(); return }
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "웹사이트"; alert.informativeText = message; alert.addButton(withTitle: "확인"); alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "웹사이트"; alert.informativeText = message; alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "취소"); alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { completionHandler(nil); return }
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "웹사이트"; alert.informativeText = prompt; let field = NSTextField(string: defaultText ?? ""); alert.accessoryView = field; alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "취소"); alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { completionHandler(nil); return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories; panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}

extension BrowserTab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { completionHandler(nil); model?.finishDownload(download); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename
        panel.beginSheetModal(for: window) { [weak self] result in
            let destination = result == .OK ? panel.url : nil
            completionHandler(destination)
            if destination == nil { self?.model?.finishDownload(download) }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        model?.finishDownload(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        model?.finishDownload(download)
    }
}
