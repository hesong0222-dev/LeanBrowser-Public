import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 940
            HStack(spacing: 0) {
                BrowserSidebar(model: model, compact: compact)
                    .frame(width: compact ? 72 : 224)

                if let tab = model.selectedTab {
                    BrowserWorkspace(model: model, tab: tab)
                        .id(tab.id)
                } else {
                    Color.white
                        .overlay {
                            Text("탭을 열어 주세요")
                                .foregroundStyle(Palette.secondaryText)
                        }
                }
            }
            .frame(minWidth: 760, minHeight: 560)
        }
        .background(Palette.mainChrome)
        .disabled(model.isClearingData)
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showingAgent) {
            AgentPanel(model: model, agent: model.agent)
        }
        .onAppear {
            model.agent.start()
        }
    }
}

private enum Palette {
    static let sidebar = Color(red: 32 / 255, green: 41 / 255, blue: 37 / 255)
    static let sidebarActive = Color(red: 54 / 255, green: 77 / 255, blue: 65 / 255)
    static let sidebarText = Color(red: 239 / 255, green: 246 / 255, blue: 241 / 255)
    static let sidebarMuted = Color(red: 171 / 255, green: 193 / 255, blue: 180 / 255)
    static let mainChrome = Color(red: 247 / 255, green: 248 / 255, blue: 244 / 255)
    static let mint = Color(red: 197 / 255, green: 233 / 255, blue: 215 / 255)
    static let mintDark = Color(red: 47 / 255, green: 103 / 255, blue: 76 / 255)
    static let secondaryText = Color(red: 90 / 255, green: 103 / 255, blue: 95 / 255)
    static let divider = Color.black.opacity(0.09)
}

private enum TabDragPayload {
    static let type = UTType(exportedAs: "dev.leanbrowser.desktop.tab-id")

    static func provider(for tabID: UUID) -> NSItemProvider {
        NSItemProvider(item: tabID.uuidString.data(using: .utf8) as NSData?, typeIdentifier: type.identifier)
    }

    static func accept(_ providers: [NSItemProvider], model: BrowserModel, before destinationID: UUID?, groupID: UUID?) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let value = String(data: data, encoding: .utf8), let tabID = UUID(uuidString: value) else { return }
            DispatchQueue.main.async { model.moveTab(tabID, before: destinationID, groupID: groupID) }
        }
        return true
    }
}

private struct TabSectionEndDropTarget: View {
    @ObservedObject var model: BrowserModel
    let groupID: UUID?
    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(isTargeted ? Palette.sidebarActive : Color.clear)
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onDrop(of: [TabDragPayload.type], isTargeted: $isTargeted) { providers in
                TabDragPayload.accept(providers, model: model, before: nil, groupID: groupID)
            }
            .accessibilityHidden(true)
    }
}

private struct BrandMark: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Palette.mint)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Palette.sidebar)
                .frame(width: 4, height: 16)
                .padding(.leading, 7)
                .padding(.bottom, 7)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Palette.sidebar)
                .frame(width: 13, height: 4)
                .padding(.leading, 7)
                .padding(.bottom, 7)
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel("LeanBrowser")
    }
}

private struct BrowserSidebar: View {
    @ObservedObject var model: BrowserModel
    let compact: Bool
    @State private var addingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 42)

            HStack(spacing: 10) {
                BrandMark()
                if !compact {
                    Text("LeanBrowser")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.sidebarText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 22 : 18)
            .padding(.bottom, 24)

            HStack(spacing: 8) {
                if !compact {
                    Text("탭")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.sidebarMuted)
                        .textCase(.uppercase)
                }
                Spacer(minLength: 0)
                Button {
                    guard model.canCreateGroup else { return }
                    addingGroup.toggle()
                    if !addingGroup { newGroupName = "" }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.sidebarMuted)
                .disabled(!model.canCreateGroup)
                .accessibilityLabel("탭 그룹 만들기")
            }
            .padding(.horizontal, compact ? 0 : 20)
            .padding(.bottom, 8)

            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    if addingGroup {
                        HStack(spacing: 6) {
                            TextField("그룹 이름", text: $newGroupName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onSubmit {
                                    if model.createGroup(name: newGroupName) != nil {
                                        newGroupName = ""
                                        addingGroup = false
                                    }
                                }
                            Button {
                                if model.createGroup(name: newGroupName) != nil {
                                    newGroupName = ""
                                    addingGroup = false
                                }
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.mint)
                            .disabled(!model.canCreateGroup)
                            .accessibilityLabel("그룹 추가")
                        }
                        .padding(.horizontal, compact ? 2 : 8)
                        .padding(.bottom, 4)
                    }

                    ForEach(model.groups) { group in
                        SidebarGroupSection(
                            model: model,
                            group: group,
                            tabs: model.tabs.filter { $0.groupID == group.id },
                            compact: compact
                        )
                    }

                    let ungroupedTabs = model.tabs.filter { $0.groupID == nil }
                    if !ungroupedTabs.isEmpty {
                        if !model.groups.isEmpty && !compact {
                            Text("그룹 없음")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.sidebarMuted)
                                .textCase(.uppercase)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                        }
                        ForEach(ungroupedTabs, id: \.id) { tab in
                            sidebarTabRow(tab)
                        }
                        TabSectionEndDropTarget(model: model, groupID: nil)
                    }
                }
                .padding(.horizontal, compact ? 10 : 12)
            }

            Spacer(minLength: 14)

            VStack(spacing: 5) {
                SidebarActionButton(
                    title: "새 탭",
                    systemImage: "plus",
                    compact: compact,
                    action: { model.newTab() }
                )
                SidebarActionButton(
                    title: "에이전트",
                    systemImage: "sparkles",
                    compact: compact,
                    action: { model.showingAgent = true }
                )
                SidebarActionButton(
                    title: "설정",
                    systemImage: "gearshape",
                    compact: compact,
                    action: { model.showingSettings = true }
                )
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.bottom, 16)
        }
        .background(Palette.sidebar)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func sidebarTabRow(_ tab: BrowserTab) -> some View {
        SidebarTabRow(
            tab: tab,
            selected: tab.id == model.selectedID,
            compact: compact,
            groups: model.groups,
            onSelect: { model.selectTab(tab.id) },
            onClose: { model.closeTab(tab.id) },
            onMove: { model.assignTab(tab.id, groupID: $0) },
            onDrop: { TabDragPayload.accept($0, model: model, before: tab.id, groupID: tab.groupID) }
        )
    }
}

private struct SidebarGroupSection: View {
    @ObservedObject var model: BrowserModel
    let group: BrowserTabGroup
    let tabs: [BrowserTab]
    let compact: Bool
    @State private var renaming = false
    @State private var name = ""
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Button {
                    model.setGroupCollapsed(group.id, collapsed: !group.isCollapsed)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 12)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .medium))
                        if !compact {
                            Text(group.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(tabs.count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Palette.sidebarMuted)
                        }
                    }
                    .foregroundStyle(Palette.sidebarMuted)
                    .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.name), \(tabs.count)개 탭")
                .accessibilityValue(group.isCollapsed ? "접힘" : "펼침")
                .contextMenu {
                    Button("이름 변경") {
                        name = group.name
                        renaming = true
                    }
                    Button("그룹 삭제", role: .destructive) {
                        model.deleteGroup(group.id)
                    }
                }
                if !compact {
                    Button {
                        model.assignTab(model.selectedID, groupID: group.id)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.sidebarMuted)
                    .disabled(model.selectedTab?.groupID == group.id)
                    .help("현재 탭을 \(group.name)에 추가")
                    .accessibilityLabel("현재 탭을 \(group.name)에 추가")
                }
            }
            .padding(.horizontal, compact ? 0 : 8)
            .background(isDropTarget ? Palette.sidebarActive : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onDrop(of: [TabDragPayload.type], isTargeted: $isDropTarget) { providers in
                TabDragPayload.accept(providers, model: model, before: nil, groupID: group.id)
            }

            if renaming {
                HStack(spacing: 6) {
                    TextField("그룹 이름", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { commitRename() }
                    Button(action: commitRename) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.mint)
                    .accessibilityLabel("그룹 이름 저장")
                }
                .padding(.horizontal, compact ? 2 : 8)
                .padding(.bottom, 3)
            }

            if !group.isCollapsed {
                ForEach(tabs, id: \.id) { tab in
                    SidebarTabRow(
                        tab: tab,
                        selected: tab.id == model.selectedID,
                        compact: compact,
                        groups: model.groups,
                        onSelect: { model.selectTab(tab.id) },
                        onClose: { model.closeTab(tab.id) },
                        onMove: { model.assignTab(tab.id, groupID: $0) },
                        onDrop: { TabDragPayload.accept($0, model: model, before: tab.id, groupID: tab.groupID) }
                    )
                }
                TabSectionEndDropTarget(model: model, groupID: group.id)
            }
        }
    }

    private func commitRename() {
        model.renameGroup(group.id, name: name)
        renaming = false
    }
}

private struct SidebarTabRow: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let compact: Bool
    let groups: [BrowserTabGroup]
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMove: (UUID?) -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var hovering = false
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                tabLabel
            }
            .buttonStyle(.plain)

            if !compact && (hovering || selected) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.sidebarMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("탭 닫기")
            }
        }
        .padding(.horizontal, compact ? 0 : 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background((selected || isDropTarget) ? Palette.sidebarActive : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onDrag { TabDragPayload.provider(for: tab.id) }
        .onDrop(of: [TabDragPayload.type], isTargeted: $isDropTarget, perform: onDrop)
        .help(tab.isHome ? "새 탭" : (tab.title.isEmpty ? "새 탭" : tab.title))
        .accessibilityLabel(tab.isHome ? "새 탭" : (tab.title.isEmpty ? "새 탭" : tab.title))
        .accessibilityValue(tab.isSuspended ? "대기 중" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("탭 닫기", role: .destructive, action: onClose)
            Divider()
            Menu("그룹으로 이동") {
                Button("그룹 해제") { onMove(nil) }
                ForEach(groups) { group in
                    Button(group.name) { onMove(group.id) }
                }
            }
        }
    }

    private var tabLabel: some View {
        HStack(spacing: 9) {
            Image(systemName: tab.isHome ? "house.fill" : (tab.isSuspended ? "moon.zzz.fill" : "globe"))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20)
                .foregroundStyle(selected ? Palette.mint : Palette.sidebarMuted)
                .opacity(tab.isSuspended ? 0.72 : 1)

            if !compact {
                Text(tab.isHome ? "새 탭" : (tab.title.isEmpty ? "새 탭" : tab.title))
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(Palette.sidebarText)
                    .opacity(tab.isSuspended ? 0.72 : 1)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .contentShape(Rectangle())
    }
}

private struct SidebarActionButton: View {
    let title: String
    let systemImage: String
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                if !compact {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(Palette.sidebarText)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .frame(height: 34)
            .padding(.horizontal, compact ? 0 : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct BrowserWorkspace: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: BrowserTab
    @State private var addressText = ""
    @State private var addressFocused = false
    @State private var lastFocusToken = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 42)
            BrowserToolbar(
                model: model,
                tab: tab,
                addressText: $addressText,
                addressFocused: $addressFocused,
                focusToken: model.focusAddressToken,
                onSubmit: submitAddress,
                onEscape: restoreAddress
            )

            if tab.isLoading {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Palette.mintDark)
                        .frame(width: max(2, geometry.size.width * min(max(tab.estimatedProgress, 0.02), 1)), height: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 2)
            }

            ZStack {
                if tab.isHome {
                    HomeView(model: model)
                } else {
                    WebViewHost(tab: tab)
                        .background(Color.white)
                }

                if let error = tab.errorMessage, !error.isEmpty {
                    ErrorPanel(
                        message: error,
                        retry: { model.reloadOrStop() },
                        editAddress: { model.focusAddress() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .background(Palette.mainChrome)
        .onAppear {
            addressText = addressValue
            lastFocusToken = model.focusAddressToken
        }
        .onChange(of: model.focusAddressToken) { _, token in
            lastFocusToken = token
            addressText = addressValue
            addressFocused = true
        }
        .onChange(of: tab.url) { _, _ in
            if !addressFocused {
                addressText = addressValue
            }
        }
    }

    private var addressValue: String {
        tab.url?.absoluteString ?? ""
    }

    private func submitAddress(_ value: String) {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            addressFocused = false
            restoreAddress()
            return
        }
        addressFocused = false
        model.navigate(input)
    }

    private func restoreAddress() {
        addressFocused = false
        addressText = addressValue
    }
}

private struct BrowserToolbar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: BrowserTab
    @Binding var addressText: String
    @Binding var addressFocused: Bool
    let focusToken: Int
    let onSubmit: (String) -> Void
    let onEscape: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ToolbarButton(
                systemImage: "chevron.left",
                label: "뒤로",
                action: { model.back() },
                disabled: !tab.canGoBack
            )
            ToolbarButton(
                systemImage: "chevron.right",
                label: "앞으로",
                action: { model.forward() },
                disabled: !tab.canGoForward
            )
            ToolbarButton(
                systemImage: tab.isLoading ? "xmark" : "arrow.clockwise",
                label: tab.isLoading ? "중지" : "새로고침",
                action: { model.reloadOrStop() },
                disabled: false
            )

            HStack(spacing: 8) {
                Image(systemName: addressStateSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityHidden(true)
                AddressField(
                    text: $addressText,
                    isFocused: $addressFocused,
                    focusToken: focusToken,
                    placeholder: "주소 또는 검색",
                    onSubmit: onSubmit,
                    onEscape: onEscape
                )
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 180, maxWidth: .infinity)
            .frame(height: 34)
            .background(Color.white)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Palette.divider, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)

            ToolbarButton(
                systemImage: "house",
                label: "홈",
                action: { model.home() },
                disabled: tab.isHome
            )
            ToolbarButton(
                systemImage: "key.fill",
                label: "저장된 로그인 채우기",
                action: { model.fillSavedCredential() },
                disabled: tab.isHome || !model.saveCredentials
            )
            if let status = model.credentialStatus {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .accessibilityLabel(status)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Palette.mainChrome)
    }

    private var addressStateSymbol: String {
        if tab.isHome {
            return "house"
        }
        return tab.url?.scheme?.lowercased() == "https" ? "lock.fill" : "globe"
    }
}

private struct ToolbarButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    let disabled: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(disabled ? Palette.secondaryText.opacity(0.35) : Palette.secondaryText)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct AddressField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusToken: Int
    let placeholder: String
    let onSubmit: (String) -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> AddressTextField {
        let field = AddressTextField(string: text)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.bezelStyle = .squareBezel
        field.focusRingType = .none
        field.alignment = .left
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.escape()
        }
        return field
    }

    func updateNSView(_ nsView: AddressTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape

        if !isFocused {
            if nsView.stringValue != text {
                nsView.stringValue = text
            }
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                context.coordinator.isFocused.wrappedValue = true
                window.makeFirstResponder(nsView)
                nsView.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onSubmit: (String) -> Void
        var onEscape: () -> Void
        var lastFocusToken = 0

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onSubmit: @escaping (String) -> Void,
            onEscape: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        @objc func submit(_ sender: NSTextField) {
            onSubmit(sender.stringValue)
            sender.window?.makeFirstResponder(nil)
        }

        func escape() {
            onEscape()
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }
    }
}

private final class AddressTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
        window?.makeFirstResponder(nil)
    }
}

private struct HomeView: View {
    @ObservedObject var model: BrowserModel
    @State private var query = ""

    private let quickLinks: [(String, String, String)] = [
        ("ChatGPT", "sparkles", "https://chatgpt.com/"),
        ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com/"),
        ("Wikipedia", "book", "https://www.wikipedia.org/")
    ]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 46)

                BrandMark()
                    .scaleEffect(1.35)
                    .padding(.bottom, 22)

                Text("LEANBROWSER")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(Palette.mintDark)
                    .padding(.bottom, 14)

                Text("어디로 이동할까요?")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color(red: 36 / 255, green: 48 / 255, blue: 41 / 255))
                    .padding(.bottom, 8)

                Text("주소를 입력하거나 검색해서 시작하세요.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.bottom, 24)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.secondaryText)
                    TextField("주소 또는 검색", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { submit() }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.secondaryText.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("검색어 지우기")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .frame(maxWidth: min(560, max(300, geometry.size.width - 72)))
                .background(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Palette.divider, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
                .padding(.bottom, 34)

                HStack(spacing: 10) {
                    ForEach(quickLinks, id: \.0) { link in
                        Button {
                            model.navigate(link.2)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: link.1)
                                    .font(.system(size: 12, weight: .medium))
                                Text(link.0)
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(Palette.mainChrome)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(link.0) 열기")
                    }
                }

                Spacer(minLength: 30)

                Text("당신의 브라우저, 당신의 공간.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText.opacity(0.8))
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
    }

    private func submit() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.navigate(value)
        query = ""
    }
}

private struct ErrorPanel: View {
    let message: String
    let retry: () -> Void
    let editAddress: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.orange)
            Text("페이지를 불러오지 못했습니다")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 430)
            HStack(spacing: 10) {
                Button("다시 시도", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.mintDark)
                Button("주소 편집", action: editAddress)
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 6)
        .padding(24)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var confirmingCredentialDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("설정")
                        .font(.system(size: 21, weight: .semibold))
                    Text("LeanBrowser의 동작을 조정합니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("검색")
                    .font(.system(size: 13, weight: .semibold))
                Picker("검색 엔진", selection: $model.searchEngine) {
                    Text("DuckDuckGo").tag("DuckDuckGo")
                    Text("Google").tag("Google")
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("이전 탭 복원", isOn: $model.restoreTabs)
                Text("다음 실행 때 마지막 세션의 탭을 다시 엽니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("메모리 절약", isOn: $model.memorySaver)
                Text("오래 사용하지 않은 탭을 쉬게 하고, 다시 선택하면 불러옵니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("로그인 정보 자동 저장", isOn: $model.saveCredentials)
                Text("지원되는 사이트에서 제출한 로그인 정보를 이 Mac의 Keychain에 저장합니다. 로그인 성공 여부는 확인하지 않습니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("저장된 로그인 정보 모두 삭제", role: .destructive) { confirmingCredentialDelete = true }
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("프로필")
                    .font(.system(size: 13, weight: .semibold))
                Text("로그인과 사이트 데이터는 LeanBrowser 전용 저장소에서 관리됩니다. 일반 브라우저 프로필을 복사하거나 공유하지 않습니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("데이터")
                    .font(.system(size: 13, weight: .semibold))
                Button("검색 기록 및 사이트 데이터 지우기", role: .destructive) {
                    confirmingClear = true
                }
                .buttonStyle(.bordered)
                Text("이 작업은 현재 LeanBrowser 전용 저장소의 브라우징 데이터를 삭제합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 440, height: 560)
        .disabled(model.isClearingData)
        .interactiveDismissDisabled(model.isClearingData)
        .overlay {
            if model.isClearingData { ProgressView("데이터 지우는 중…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .confirmationDialog(
            "저장된 로그인 정보를 모두 삭제할까요?",
            isPresented: $confirmingCredentialDelete,
            titleVisibility: .visible
        ) {
            Button("모두 삭제", role: .destructive) { model.deleteSavedCredentials() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("LeanBrowser가 저장한 로그인 정보가 이 Mac의 Keychain에서 삭제됩니다.")
        }
        .confirmationDialog(
            "브라우징 데이터를 지울까요?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("지우기", role: .destructive) {
                Task { await model.clearBrowsingData() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("진행 중인 다운로드를 취소하고 LeanBrowser 전용 사이트 데이터와 기록을 삭제합니다.")
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab

    func makeNSView(context: Context) -> WKWebView {
        tab.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView !== tab.webView {
            nsView.removeFromSuperview()
        }
    }
}
