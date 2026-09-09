import AppKit
import ApplicationServices

@MainActor
final class DesktopAgent {
    private struct Snapshot {
        let id: String
        let pid: pid_t
        let createdAt: Date
        let elements: [String: SnapshotElement]
    }

    private struct SnapshotElement {
        let element: AXUIElement
        let fingerprint: ElementFingerprint
    }

    private struct ElementFingerprint: Equatable {
        let role: String
        let subrole: String
        let identifier: String
        let title: String
        let description: String
    }

    private struct WindowReference {
        let token: String
        let pid: pid_t
        let createdAt: Date
        let element: AXUIElement
        let fingerprint: ElementFingerprint
    }

    private enum AgentError: LocalizedError {
        case invalidArguments(String)
        case permissionDenied
        case unavailable(String)
        case unknownOperation(String)
        case staleSnapshot
        case unsupportedAction(String)
        case protectedElement
        case accessibility(String)

        var errorDescription: String? {
            switch self {
            case .invalidArguments(let detail): return "Invalid desktop-agent arguments: \(detail)"
            case .permissionDenied: return "Accessibility permission is required. Enable LeanBrowser in System Settings > Privacy & Security > Accessibility."
            case .unavailable(let detail): return "Desktop target is unavailable: \(detail)"
            case .unknownOperation(let operation): return "Unknown desktop operation: \(operation)"
            case .staleSnapshot: return "This desktop snapshot has expired or changed. Take a new snapshot before acting."
            case .unsupportedAction(let action): return "The element does not advertise the requested accessibility action: \(action)"
            case .protectedElement: return "Secure text fields cannot be read or edited."
            case .accessibility(let detail): return "Accessibility operation failed: \(detail)"
            }
        }
    }

    private var snapshots: [String: Snapshot] = [:]
    private var windowReferences: [pid_t: [[String: WindowReference]]] = [:]
    private let snapshotLifetime: TimeInterval = 60
    private let maximumSnapshots = 4
    private let maximumWindowInventoriesPerProcess = 4
    private let maximumWindowsPerInventory = 100
    private let maximumNodes = 400
    private let maximumDepth = 12
    private let snapshotDeadline: TimeInterval = 1.5
    private let accessibilityMessageTimeout: Float = 0.1

    func status() -> [String: Any] {
        pruneSnapshots()
        return [
            "accessibilityTrusted": AXIsProcessTrusted(),
            "snapshotCount": snapshots.count,
            "snapshotLifetimeSeconds": Int(snapshotLifetime),
            "maxSnapshotNodes": maximumNodes,
        ]
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func execute(_ operation: String, arguments: [String: Any]) throws -> [String: Any] {
        switch operation {
        case "desktop.apps":
            return ["apps": runningApps()]
        case "desktop.windows":
            try requireAccessibilityPermission()
            let pid = try requiredPID(arguments)
            return ["pid": Int(pid), "windows": try windows(for: pid)]
        case "desktop.snapshot":
            try requireAccessibilityPermission()
            let pid = try requiredPID(arguments)
            return try snapshot(for: pid, arguments: arguments)
        case "desktop.action":
            try requireAccessibilityPermission()
            return try performAction(arguments)
        case "desktop.setValue":
            try requireAccessibilityPermission()
            return try setValue(arguments)
        case "desktop.activate":
            try requireAccessibilityPermission()
            return try activate(arguments)
        case "desktop.key":
            try requireAccessibilityPermission()
            return try postKey(arguments)
        default:
            throw AgentError.unknownOperation(operation)
        }
    }

    private func runningApps() -> [[String: Any]] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { app in
                [
                    "pid": Int(app.processIdentifier),
                    "bundleId": app.bundleIdentifier ?? "",
                    "name": app.localizedName ?? "",
                    "active": app.isActive,
                ]
            }
    }

    private func windows(for pid: pid_t) throws -> [[String: Any]] {
        pruneWindowReferences()
        let app = try applicationElement(for: pid)
        let appName = stringAttribute(app, kAXTitleAttribute)
        let elements = Array(elementArrayAttribute(app, kAXWindowsAttribute).prefix(maximumWindowsPerInventory))
        let createdAt = Date()
        var inventory: [String: WindowReference] = [:]
        let records = elements.map { window -> [String: Any] in
            AXUIElementSetMessagingTimeout(window, accessibilityMessageTimeout)
            let reference = WindowReference(
                token: UUID().uuidString,
                pid: pid,
                createdAt: createdAt,
                element: window,
                fingerprint: fingerprint(for: window)
            )
            inventory[reference.token] = reference
            var record: [String: Any] = [
                "ref": reference.token,
                "title": stringAttribute(window, kAXTitleAttribute) ?? "",
                "role": stringAttribute(window, kAXRoleAttribute) ?? "",
                "appName": appName ?? "",
            ]
            if let windowNumber = numberAttribute(window, "AXWindowNumber") {
                record["id"] = windowNumber
            }
            return record
        }
        windowReferences[pid, default: []].append(inventory)
        trimWindowInventories(for: pid)
        return records
    }

    private func snapshot(for pid: pid_t, arguments: [String: Any]) throws -> [String: Any] {
        let app = try applicationElement(for: pid)
        let selectedRoot = try snapshotRoot(app: app, pid: pid, arguments: arguments)
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(snapshotDeadline)
        var elements: [String: SnapshotElement] = [:]
        var records: [[String: Any]] = []
        var nextIndex = 0
        var encodedBytes = 0
        var truncated = false

        func visit(_ element: AXUIElement, parent: String?, depth: Int) {
            guard !truncated else { return }
            if depth > maximumDepth || records.count >= maximumNodes || deadlineExceeded(deadline) {
                truncated = true
                return
            }
            AXUIElementSetMessagingTimeout(element, accessibilityMessageTimeout)
            let ref = "e\(nextIndex)"
            nextIndex += 1
            elements[ref] = SnapshotElement(element: element, fingerprint: fingerprint(for: element))
            guard !deadlineExceeded(deadline) else { truncated = true; return }
            let secure = isSecure(element)
            guard !deadlineExceeded(deadline) else { truncated = true; return }
            let actions = actionNames(element).compactMap(publicActionName)
            guard !deadlineExceeded(deadline) else { truncated = true; return }
            var record: [String: Any] = [
                "ref": ref,
                "role": stringAttribute(element, kAXRoleAttribute) ?? "",
                "name": stringAttribute(element, kAXTitleAttribute) ?? stringAttribute(element, kAXDescriptionAttribute) ?? "",
                "actions": actions,
                "settable": !secure && isAttributeSettable(element, kAXValueAttribute),
            ]
            if let parent { record["parent"] = parent }
            if !secure, let value = safeValueAttribute(element) { record["value"] = value }
            guard !deadlineExceeded(deadline) else { truncated = true; return }
            guard let encoded = try? JSONSerialization.data(withJSONObject: record), encodedBytes + encoded.count <= 196_608 else {
                elements.removeValue(forKey: ref)
                truncated = true
                return
            }
            encodedBytes += encoded.count
            records.append(record)
            for child in elementArrayAttribute(element, kAXChildrenAttribute) {
                visit(child, parent: ref, depth: depth + 1)
            }
        }

        visit(selectedRoot, parent: nil, depth: 0)
        let id = UUID().uuidString
        snapshots[id] = Snapshot(id: id, pid: pid, createdAt: startedAt, elements: elements)
        pruneSnapshots()
        return [
            "snapshot": id,
            "pid": Int(pid),
            "app": ["name": stringAttribute(app, kAXTitleAttribute) ?? ""],
            "window": windowMetadata(selectedRoot),
            "elements": records,
            "truncated": truncated,
            "nodeCount": records.count,
        ]
    }

    private func snapshotRoot(app: AXUIElement, pid: pid_t, arguments: [String: Any]) throws -> AXUIElement {
        guard let requested = arguments["window"] ?? arguments["windowId"] else { return app }
        let available = elementArrayAttribute(app, kAXWindowsAttribute)
        if let token = requested as? String {
            guard let reference = windowReference(token: token, pid: pid),
                  available.contains(where: { CFEqual($0, reference.element) }) else {
                throw AgentError.staleSnapshot
            }
            AXUIElementSetMessagingTimeout(reference.element, accessibilityMessageTimeout)
            guard fingerprint(for: reference.element) == reference.fingerprint else {
                throw AgentError.staleSnapshot
            }
            return reference.element
        }
        let wanted = try integer(requested, named: "window")
        if let matching = available.first(where: { numberAttribute($0, "AXWindowNumber") == wanted }) { return matching }
        throw AgentError.unavailable("window \(wanted)")
    }

    private func performAction(_ arguments: [String: Any]) throws -> [String: Any] {
        let (_, snapshot, element) = try snapshotElement(arguments)
        guard !isSecure(element) else { throw AgentError.protectedElement }
        let requested = try requiredString(arguments, "action")
        let axAction = try actionName(for: requested)
        guard actionNames(element).contains(axAction) else { throw AgentError.unsupportedAction(requested) }
        let result = AXUIElementPerformAction(element, axAction as CFString)
        guard result == .success else { throw AgentError.accessibility("\(result.rawValue) while performing \(requested)") }
        invalidateSnapshots(for: snapshot.pid)
        return ["ok": true, "snapshotInvalidated": true, "pid": Int(snapshot.pid)]
    }

    private func setValue(_ arguments: [String: Any]) throws -> [String: Any] {
        let (_, snapshot, element) = try snapshotElement(arguments)
        guard !isSecure(element) else { throw AgentError.protectedElement }
        guard isAttributeSettable(element, kAXValueAttribute) else { throw AgentError.unsupportedAction("setValue") }
        guard let value = arguments["value"] as? String else { throw AgentError.invalidArguments("missing or invalid value") }
        guard value.utf8.count <= 8_192 else { throw AgentError.invalidArguments("value exceeds 8192 bytes") }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard result == .success else { throw AgentError.accessibility("\(result.rawValue) while setting value") }
        invalidateSnapshots(for: snapshot.pid)
        return ["ok": true, "snapshotInvalidated": true, "pid": Int(snapshot.pid)]
    }

    private func activate(_ arguments: [String: Any]) throws -> [String: Any] {
        let pid = try requiredPID(arguments)
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { throw AgentError.unavailable("pid \(pid)") }
        guard app.activate(options: [.activateAllWindows]) else { throw AgentError.unavailable("could not activate pid \(pid)") }
        invalidateSnapshots(for: pid)
        return ["ok": true, "pid": Int(pid)]
    }

    private func postKey(_ arguments: [String: Any]) throws -> [String: Any] {
        let pid = try requiredPID(arguments)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw AgentError.unavailable("pid \(pid) is not frontmost") }
        let key = try requiredString(arguments, "key")
        guard let keyCode = keyCodes[key] else { throw AgentError.invalidArguments("unsupported key \(key)") }
        var flags: CGEventFlags = []
        if let rawModifiers = arguments["modifiers"] {
            guard let modifiers = rawModifiers as? [String] else { throw AgentError.invalidArguments("modifiers must be an array of strings") }
            for modifier in modifiers {
                guard let flag = modifierFlags[modifier] else { throw AgentError.invalidArguments("unsupported modifier \(modifier)") }
                flags.insert(flag)
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw AgentError.unavailable("could not create key event")
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        invalidateSnapshots(for: pid)
        return ["ok": true, "pid": Int(pid), "key": key]
    }

    private func snapshotElement(_ arguments: [String: Any]) throws -> (String, Snapshot, AXUIElement) {
        pruneSnapshots()
        let id = try requiredString(arguments, "snapshot")
        guard let snapshot = snapshots[id], isRunning(snapshot.pid) else { throw AgentError.staleSnapshot }
        let ref = try requiredString(arguments, "ref")
        guard let stored = snapshot.elements[ref] else { throw AgentError.staleSnapshot }
        AXUIElementSetMessagingTimeout(stored.element, accessibilityMessageTimeout)
        guard fingerprint(for: stored.element) == stored.fingerprint else { throw AgentError.staleSnapshot }
        return (id, snapshot, stored.element)
    }

    private func applicationElement(for pid: pid_t) throws -> AXUIElement {
        guard isRunning(pid) else { throw AgentError.unavailable("pid \(pid)") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, accessibilityMessageTimeout)
        return app
    }

    private func requireAccessibilityPermission() throws {
        guard AXIsProcessTrusted() else { throw AgentError.permissionDenied }
    }

    private func requiredPID(_ arguments: [String: Any]) throws -> pid_t {
        let raw = try required(arguments, "pid")
        let value = try integer(raw, named: "pid")
        guard value > 0, value <= Int(Int32.max) else { throw AgentError.invalidArguments("pid") }
        return pid_t(value)
    }

    private func required(_ arguments: [String: Any], _ name: String) throws -> Any {
        guard let value = arguments[name] else { throw AgentError.invalidArguments("missing \(name)") }
        return value
    }

    private func requiredString(_ arguments: [String: Any], _ name: String) throws -> String {
        guard let value = arguments[name] as? String, !value.isEmpty else { throw AgentError.invalidArguments("missing or invalid \(name)") }
        return value
    }

    private func integer(_ value: Any, named: String) throws -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        throw AgentError.invalidArguments("invalid \(named)")
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }

    private func deadlineExceeded(_ deadline: Date) -> Bool {
        Date() >= deadline
    }

    private func pruneSnapshots() {
        let now = Date()
        snapshots = snapshots.filter { now.timeIntervalSince($0.value.createdAt) <= snapshotLifetime && isRunning($0.value.pid) }
        if snapshots.count > maximumSnapshots {
            for snapshot in snapshots.values.sorted(by: { $0.createdAt < $1.createdAt }).prefix(snapshots.count - maximumSnapshots) {
                snapshots.removeValue(forKey: snapshot.id)
            }
        }
    }

    private func pruneWindowReferences() {
        let now = Date()
        windowReferences = windowReferences.reduce(into: [:]) { result, entry in
            let inventories = entry.value
                .map { inventory in
                    inventory.filter { now.timeIntervalSince($0.value.createdAt) <= snapshotLifetime && isRunning($0.value.pid) }
                }
                .filter { !$0.isEmpty }
            if !inventories.isEmpty { result[entry.key] = inventories }
        }
    }

    private func trimWindowInventories(for pid: pid_t) {
        guard var inventories = windowReferences[pid], inventories.count > maximumWindowInventoriesPerProcess else { return }
        inventories.sort { left, right in
            (left.values.first?.createdAt ?? .distantPast) > (right.values.first?.createdAt ?? .distantPast)
        }
        windowReferences[pid] = Array(inventories.prefix(maximumWindowInventoriesPerProcess))
    }

    private func windowReference(token: String, pid: pid_t) -> WindowReference? {
        pruneWindowReferences()
        return windowReferences[pid]?.lazy.compactMap { $0[token] }.first
    }

    private func invalidateSnapshots(for pid: pid_t) {
        snapshots = snapshots.filter { $0.value.pid != pid }
    }

    private func fingerprint(for element: AXUIElement) -> ElementFingerprint {
        ElementFingerprint(
            role: stringAttribute(element, kAXRoleAttribute) ?? "",
            subrole: stringAttribute(element, kAXSubroleAttribute) ?? "",
            identifier: stringAttribute(element, kAXIdentifierAttribute) ?? "",
            title: stringAttribute(element, kAXTitleAttribute) ?? "",
            description: stringAttribute(element, kAXDescriptionAttribute) ?? ""
        )
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return String(string.prefix(2_048)) }
        if let attributed = value as? NSAttributedString { return String(attributed.string.prefix(2_048)) }
        return nil
    }

    private func numberAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func safeValueAttribute(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute)
    }

    private func elementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else { return [] }
        return actions as? [String] ?? []
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        return subrole == kAXSecureTextFieldSubrole || role == "AXSecureTextField" || role == "AXSecureTextArea"
    }

    private func windowMetadata(_ element: AXUIElement) -> [String: Any] {
        [
            "id": numberAttribute(element, "AXWindowNumber") as Any,
            "title": stringAttribute(element, kAXTitleAttribute) ?? "",
            "role": stringAttribute(element, kAXRoleAttribute) ?? "",
        ]
    }

    private func actionName(for publicName: String) throws -> String {
        switch publicName {
        case "press": return kAXPressAction as String
        case "raise": return kAXRaiseAction as String
        case "confirm": return kAXConfirmAction as String
        case "cancel": return kAXCancelAction as String
        case "increment": return kAXIncrementAction as String
        case "decrement": return kAXDecrementAction as String
        case "showMenu": return kAXShowMenuAction as String
        default: throw AgentError.unsupportedAction(publicName)
        }
    }

    private func publicActionName(_ action: String) -> String? {
        switch action {
        case kAXPressAction: return "press"
        case kAXRaiseAction: return "raise"
        case kAXConfirmAction: return "confirm"
        case kAXCancelAction: return "cancel"
        case kAXIncrementAction: return "increment"
        case kAXDecrementAction: return "decrement"
        case kAXShowMenuAction: return "showMenu"
        default: return nil
        }
    }

    private let keyCodes: [String: CGKeyCode] = [
        "enter": 36, "escape": 53, "tab": 48, "backspace": 51, "space": 49,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    private let modifierFlags: [String: CGEventFlags] = [
        "command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl,
    ]
}
