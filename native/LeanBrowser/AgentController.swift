import AppKit
import Combine
import Foundation

struct AgentJob: Identifiable, Codable {
    let id: String
    var status: String
    let summary: String
    let created: Date
}

struct AgentFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class AgentController: ObservableObject {
    @Published var browserEnabled = true { didSet { if !browserEnabled { cancelAll() } } }
    @Published var desktopEnabled = false { didSet { if !desktopEnabled { cancelAll() } } }
    @Published var proposalText = ""
    @Published var notice = ""
    @Published private(set) var jobs: [AgentJob] = []
    @Published private(set) var latestResult = ""
    @Published private(set) var isImporting = false
    @Published private(set) var socketStatus = "연결 준비 중"

    private weak var model: BrowserModel?
    private let semantic = SemanticBrowser()
    private let nativeChat = NativeChat()
    private let desktop = DesktopAgent()
    private var socket: AgentSocket?
    private var activeTask: Task<Void, Never>?
    private var activeJobID: String?
    private var busy = false
    private var requestIDs: Set<String> = []
    private var requestOrder: [String] = []
    private var results: [String: [[String: Any]]] = [:]
    private var proposalSource: (id: UUID, url: String)?
    private static let ledgerKey = "dev.leanbrowser.desktop.agentJobs.v1"
    private let operations: Set<String> = ["groups.list", "groups.create", "groups.rename", "groups.delete", "tabs.group", "status", "tabs.list", "tabs.open", "tabs.close", "browser.navigate", "browser.snapshot", "browser.action", "browser.wait", "chat.read", "chat.send", "desktop.apps", "desktop.windows", "desktop.snapshot", "desktop.action", "desktop.setValue", "desktop.activate", "desktop.key"]

    init(model: BrowserModel) {
        self.model = model
        if let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
           let saved = try? JSONDecoder().decode([AgentJob].self, from: data) {
            jobs = Array(saved.prefix(20)).map { job in
                var recovered = job
                if ["queued", "running", "cancelling"].contains(recovered.status) { recovered.status = "interrupted" }
                return recovered
            }
            persistJobs()
        }
    }

    var desktopPermissionText: String {
        let state = desktop.status()
        return (state["trusted"] as? Bool == true || state["accessibilityTrusted"] as? Bool == true)
            ? "macOS 접근성 허용됨" : "macOS 접근성 권한이 필요합니다"
    }

    func start() {
        guard socket == nil else { return }
        let service = AgentSocket { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { completion(["ok": false, "error": "app_closed"]); return }
                completion(await self.receive(request))
            }
        }
        do { try service.start(); socket = service; socketStatus = "연결됨" }
        catch { socketStatus = "연결 실패: \(error.localizedDescription)" }
    }

    func stop() { cancelAll(); socket?.stop(); socket = nil }
    func requestDesktopPermission() { desktop.requestPermission(); objectWillChange.send() }
    func cancelAll() {
        activeTask?.cancel()
        if let id = activeJobID { setStatus(id, "cancelling") }
        notice = "중단 요청됨. 이미 수행한 동작은 되돌리지 않습니다."
    }

    private func receive(_ request: [String: Any]) async -> [String: Any] {
        let id = request["id"] as? String ?? ""
        do {
            guard !id.isEmpty, id.count <= 100, let operation = request["operation"] as? String,
                  let arguments = request["arguments"] as? [String: Any] else { throw AgentFailure("invalid_request: id, operation, arguments required") }
            guard !requestIDs.contains(id) else { throw AgentFailure("duplicate_request: inspect job/result; mutations are never replayed") }
            requestIDs.insert(id); requestOrder.append(id)
            if requestOrder.count > 256 { requestIDs.remove(requestOrder.removeFirst()) }
            let result: [String: Any]
            switch operation {
            case "job.list": result = ["jobs": jobs.map(jobDictionary)]
            case "job.get":
                let jobID = try string(arguments, "jobId")
                guard let job = jobs.first(where: { $0.id == jobID }) else { throw AgentFailure("unknown_job") }
                result = ["job": jobDictionary(job), "results": results[jobID] ?? [], "resultsAvailable": results[jobID] != nil]
            case "job.cancel":
                let jobID = try string(arguments, "jobId")
                guard activeJobID == jobID else { throw AgentFailure("job_not_running") }
                cancelAll(); result = ["jobId": jobID, "status": "cancelling"]
            case "job.submit":
                let commands = try validateCommands(arguments["commands"])
                result = ["jobId": try submit(commands, source: nil)]
            case "status", "tabs.list", "chat.read": result = try await execute(operation, arguments: arguments)
            default:
                guard !busy, activeTask == nil else { throw AgentFailure("busy: inspect active job, do not retry ambiguous mutations") }
                busy = true
                defer { busy = false }
                result = try await execute(operation, arguments: arguments)
            }
            if let error = result["error"] as? String {
                var response: [String: Any] = ["id": id, "ok": false, "error": error, "result": result]
                if let draftRetained = result["draftRetained"] as? Bool { response["draftRetained"] = draftRetained }
                return response
            }
            return ["id": id, "ok": true, "result": result]
        } catch { return ["id": id, "ok": false, "error": error.localizedDescription] }
    }

    private func execute(_ operation: String, arguments: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard operations.contains(operation), let model else { throw AgentFailure("unsupported_operation") }
        if operation == "status" {
            return ["version": 1, "browserEnabled": browserEnabled, "desktopEnabled": desktopEnabled,
                    "desktop": desktop.status(), "windowId": "main", "operations": operations.sorted(),
                    "jobOperations": ["job.submit", "job.list", "job.get", "job.cancel"],
                    "loginStorage": "persistent WKWebsiteDataStore; credentials are not exported",
                    "limitations": ["One LeanBrowser window", "AX coverage depends on each app", "No arbitrary shell or JavaScript", "Jobs stop when app exits; no automatic replay"]]
        }
        guard !model.isClearingData else { throw AgentFailure("browsing_data_is_being_cleared") }
        if operation.hasPrefix("desktop.") {
            guard desktopEnabled else { throw AgentFailure("desktop_control_disabled: enable in native Agent panel for this session") }
            return try desktop.execute(operation, arguments: arguments)
        }
        guard browserEnabled else { throw AgentFailure("browser_control_disabled") }
        if operation == "groups.list" { return ["groups": model.groups.map { ["groupId": $0.id.uuidString, "name": $0.name, "collapsed": $0.isCollapsed] as [String: Any] }] }
        if operation == "groups.create" {
            let name = try string(arguments, "name")
            guard name.count <= 80, model.groups.count < 32 else { throw AgentFailure("group_limit_or_name_too_long") }
            guard let group = model.createGroup(name: name) else { throw AgentFailure("group_limit_reached") }
            return ["groupId": group.id.uuidString, "name": group.name]
        }
        if operation == "groups.rename" || operation == "groups.delete" {
            guard let id = UUID(uuidString: try string(arguments, "groupId")), model.groups.contains(where: { $0.id == id }) else { throw AgentFailure("unknown_group") }
            if operation == "groups.delete" { model.deleteGroup(id) }
            else {
                let name = try string(arguments, "name")
                guard name.count <= 80 else { throw AgentFailure("group_name_too_long") }
                model.renameGroup(id, name: name)
            }
            return ["groupId": id.uuidString, "updated": true]
        }
        if operation == "tabs.list" {
            return ["windows": [["windowId": "main", "title": "LeanBrowser", "selectedTabId": model.selectedID.uuidString,
                                  "tabs": model.tabs.map { tab in ["tabId": tab.id.uuidString, "title": tab.title, "url": tab.url?.absoluteString ?? "", "loading": tab.isLoading, "suspended": tab.isSuspended, "background": tab.id != model.selectedID, "leased": tab.agentLeaseCount > 0, "groupId": tab.groupID?.uuidString as Any? ?? NSNull()] as [String: Any] }]]]
        }
        if operation == "tabs.open" {
            let url = try checkedURL(arguments)
            guard let tab = model.newTab(url: url, select: arguments["select"] as? Bool ?? false) else { throw AgentFailure("tab_limit_reached") }
            return ["tabId": tab.id.uuidString, "windowId": "main", "url": url.absoluteString]
        }
        let idString = try string(arguments, "tabId")
        guard let id = UUID(uuidString: idString), let tab = model.tabs.first(where: { $0.id == id }) else { throw AgentFailure("unknown_tab") }
        tab.agentLeaseCount += 1
        defer { tab.agentLeaseCount = max(0, tab.agentLeaseCount - 1) }
        switch operation {
        case "chat.read", "chat.send":
            guard !tab.isHome else { throw AgentFailure("home_tab: navigate first") }
            tab.resumeIfNeeded()
            guard !tab.isLoading, let view = tab.webViewIfLoaded, let url = view.url ?? tab.url else { throw AgentFailure("page_loading: call browser.wait") }
            let generation = tab.navigationGeneration
            let result = operation == "chat.read"
                ? try await nativeChat.read(webView: view, tabID: idString, url: url)
                : try await nativeChat.send(webView: view, tabID: idString, url: url, text: try string(arguments, "text"))
            guard model.tabs.contains(where: { $0 === tab }), tab.webViewIfLoaded === view, tab.navigationGeneration == generation else {
                if result["dispatched"] as? Bool == true {
                    var uncertain = result
                    uncertain["status"] = "dispatched_uncertain"
                    uncertain["uncertain"] = true
                    uncertain["targetChangedAfterDispatch"] = true
                    return uncertain
                }
                throw AgentFailure("target_changed: inspect before continuing")
            }
            return result
        case "tabs.group":
            let groupID: UUID?
            if let value = arguments["groupId"] as? String {
                guard let parsed = UUID(uuidString: value), model.groups.contains(where: { $0.id == parsed }) else { throw AgentFailure("unknown_group") }
                groupID = parsed
            } else if arguments["groupId"] is NSNull { groupID = nil }
            else { throw AgentFailure("groupId: UUID string or explicit null required") }
            model.assignTab(id, groupID: groupID)
            return ["tabId": idString, "groupId": groupID?.uuidString as Any? ?? NSNull()]
        case "tabs.close": model.closeTab(id); return ["closed": idString]
        case "browser.navigate":
            let url = try checkedURL(arguments)
            model.load(url, in: tab)
            return ["tabId": idString, "url": url.absoluteString, "loading": true]
        case "browser.wait":
            let timeout = min(10.0, max(0.1, (arguments["timeoutMs"] as? Double ?? 5000) / 1000))
            tab.resumeIfNeeded()
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                try Task.checkCancellation()
                guard browserEnabled, !model.isClearingData, model.tabs.contains(where: { $0 === tab }) else { throw AgentFailure("target_unavailable") }
                if let error = tab.errorMessage { throw AgentFailure(error) }
                if tab.isHome || (!tab.isLoading && tab.webViewIfLoaded?.isLoading == false && tab.webViewIfLoaded?.url != nil) { return ["tabId": idString, "ready": true, "url": tab.url?.absoluteString ?? ""] }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < deadline
            throw AgentFailure("wait_timeout: inspect page before another action")
        case "browser.snapshot", "browser.action":
            guard !tab.isHome else { throw AgentFailure("home_tab: navigate first") }
            tab.resumeIfNeeded()
            guard !tab.isLoading, tab.webViewIfLoaded?.isLoading == false, tab.webViewIfLoaded?.url != nil else { throw AgentFailure("page_loading: call browser.wait") }
            let view = tab.webView
            let generation = tab.navigationGeneration
            let result: [String: Any]
            if operation == "browser.snapshot" { result = try await semantic.snapshot(webView: view, tabID: idString, generation: generation) }
            else { result = try await semantic.action(webView: view, tabID: idString, generation: generation, arguments: arguments) }
            guard model.tabs.contains(where: { $0 === tab }), tab.webViewIfLoaded === view else { throw AgentFailure("target_changed: inspect before continuing") }
            return result
        default: throw AgentFailure("unsupported_operation")
        }
    }

    private func checkedURL(_ arguments: [String: Any]) throws -> URL {
        let text = try string(arguments, "url")
        guard text.count <= 8192, let url = URL(string: text), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { throw AgentFailure("invalid_url: http/https without credentials required") }
        return url
    }
    private func string(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else { throw AgentFailure("missing_\(key)") }
        return value
    }
    private func validateCommands(_ value: Any?) throws -> [[String: Any]] {
        guard let commands = value as? [[String: Any]], (1...8).contains(commands.count) else { throw AgentFailure("commands: 1...8 commands required") }
        for command in commands {
            guard Set(command.keys) == Set(["operation", "arguments"]), let operation = command["operation"] as? String,
                  operations.contains(operation), command["arguments"] is [String: Any] else { throw AgentFailure("invalid_command: unsupported operation or fields") }
        }
        return commands
    }

    private func submit(_ commands: [[String: Any]], source: (id: UUID, url: String)?) throws -> String {
        guard !busy, activeTask == nil else { throw AgentFailure("busy_or_disabled") }
        for command in commands {
            let operation = command["operation"] as? String ?? ""
            if operation == "status" { continue }
            guard operation.hasPrefix("desktop.") ? desktopEnabled : browserEnabled else { throw AgentFailure("required_capability_disabled") }
        }
        let id = UUID().uuidString
        let summary = commands.compactMap { $0["operation"] as? String }.joined(separator: " → ")
        jobs.insert(AgentJob(id: id, status: "queued", summary: summary, created: Date()), at: 0)
        jobs = Array(jobs.prefix(20))
        results = results.filter { key, _ in jobs.prefix(3).contains { $0.id == key } }
        persistJobs()
        activeJobID = id
        activeTask = Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            let ids = Set(commands.compactMap { ($0["arguments"] as? [String: Any])?["tabId"] as? String })
            let leased = model.tabs.filter { ids.contains($0.id.uuidString) }
            leased.forEach { $0.agentLeaseCount += 1 }
            defer {
                leased.forEach { $0.agentLeaseCount = max(0, $0.agentLeaseCount - 1) }
                self.activeTask = nil; self.activeJobID = nil
            }
            self.setStatus(id, "running")
            var collected: [[String: Any]] = []
            do {
                for command in commands {
                    try Task.checkCancellation()
                    if let source {
                        guard model.tabs.contains(where: { $0.id == source.id && $0.url?.absoluteString == source.url }) else { throw AgentFailure("chat_source_changed") }
                    }
                    let operation = command["operation"] as! String
                    let result = try await self.execute(operation, arguments: command["arguments"] as! [String: Any])
                    let domainError = result["error"] as? String
                    let entry: [String: Any] = ["operation": operation, "ok": domainError == nil, "result": result]
                    let bytes = (try? JSONSerialization.data(withJSONObject: collected + [entry]).count) ?? Int.max
                    collected.append(bytes <= 262_144 ? entry : ["operation": operation, "ok": domainError == nil, "resultOmitted": true, "reason": "job_result_budget"] )
                    self.results[id] = collected
                    if let domainError { throw AgentFailure(domainError) }
                }
                try Task.checkCancellation()
                self.setStatus(id, "completed")
                self.notice = "계획 실행 완료"
            } catch {
                let cancelled = error is CancellationError
                collected.append(["ok": false, "error": cancelled ? "cancelled: completed actions remain" : error.localizedDescription])
                self.setStatus(id, cancelled ? "cancelled" : "failed")
                self.notice = cancelled ? "작업 중단됨" : error.localizedDescription
            }
            self.results[id] = collected
            self.latestResult = Self.json(["jobId": id, "results": collected])
        }
        return id
    }

    func importChat() async {
        guard !isImporting, let tab = model?.selectedTab, !tab.isHome, !tab.isLoading else { notice = "불러온 채팅 탭을 선택하세요."; return }
        isImporting = true
        defer { isImporting = false }
        do {
            let source = (id: tab.id, url: tab.url?.absoluteString ?? "")
            let text = try await semantic.chatProposal(webView: tab.webView)
            guard tab.url?.absoluteString == source.url else { throw AgentFailure("chat_source_changed") }
            _ = try parseProposal(text)
            proposalText = text; proposalSource = source
            notice = "가져온 명령을 확인한 뒤 계획 실행을 누르세요."
        } catch { notice = error.localizedDescription }
    }
    private func parseProposal(_ text: String) throws -> [[String: Any]] {
        guard text.utf8.count <= 32768, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["leanbrowser", "commands"]), object["leanbrowser"] as? Int == 1 else { throw AgentFailure("JSON 형식: {\"leanbrowser\":1,\"commands\":[{\"operation\":\"tabs.list\",\"arguments\":{}}]}") }
        return try validateCommands(object["commands"])
    }
    func runProposal() {
        do { let commands = try parseProposal(proposalText); _ = try submit(commands, source: proposalSource) }
        catch { notice = error.localizedDescription }
    }
    func copyInstructions() { copy(SemanticBrowser.chatInstructions); notice = "채팅용 도구 사용법을 복사했습니다." }
    func copyResult() { copy(latestResult); notice = "결과를 복사했습니다. 전송할 채팅을 직접 선택하세요." }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func setStatus(_ id: String, _ status: String) { if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].status = status; persistJobs() } }
    private func persistJobs() { if let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: Self.ledgerKey) } }
    private func jobDictionary(_ job: AgentJob) -> [String: Any] { ["jobId": job.id, "status": job.status, "summary": job.summary, "created": ISO8601DateFormatter().string(from: job.created)] }
    private static func json(_ value: Any) -> String { guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }; return String(decoding: data, as: UTF8.self) }
}
