import AppKit
import SwiftUI

@MainActor
private final class LeanBrowserAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: BrowserModel?

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.saveSession()
        Self.model?.agent.stop()
    }
}

@MainActor
private struct LeanBrowserCommands: Commands {
    @ObservedObject var model: BrowserModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 탭") {
                model.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)

        }

        CommandGroup(replacing: .saveItem) {
            Button("탭 닫기") {
                closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("닫은 탭 다시 열기") {
                model.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Button("주소 입력란 포커스") {
                model.focusAddress()
            }
            .keyboardShortcut("l", modifiers: .command)
        }

        if let tab = model.selectedTab {
            NavigationCommands(model: model, tab: tab)
        }

        CommandMenu("탭 선택") {
            ForEach(0..<9, id: \.self) { index in
                Button(tabLabel(at: index)) {
                    selectTab(at: index)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(!model.tabs.indices.contains(index))
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("에이전트") {
                model.showingAgent = true
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button("설정") {
                model.showingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .appTermination) {
            Button("LeanBrowser 종료") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func closeSelectedTab() {
        guard let selectedID = model.selectedTab?.id else { return }
        model.closeTab(selectedID)
    }

    private func selectTab(at index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        model.selectTab(model.tabs[index].id)
    }

    private func tabLabel(at index: Int) -> String { "탭 \(index + 1)" }

}

@MainActor
private struct NavigationCommands: Commands {
    let model: BrowserModel
    @ObservedObject var tab: BrowserTab

    var body: some Commands {
        CommandMenu("탐색") {
            Button("뒤로") { model.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!tab.canGoBack)
            Button("앞으로") { model.forward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!tab.canGoForward)
            Button("새로 고침") { model.reloadOrStop() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(tab.isHome)
            Button("홈") { model.home() }
                .disabled(tab.isHome)
        }
    }
}

@main
@MainActor
struct LeanBrowserApp: App {
    @StateObject private var model: BrowserModel
    @NSApplicationDelegateAdaptor(LeanBrowserAppDelegate.self) private var appDelegate

    init() {
        let model = BrowserModel()
        _model = StateObject(wrappedValue: model)
        LeanBrowserAppDelegate.model = model
    }

    var body: some Scene {
        Window("LeanBrowser", id: "main") {
            BrowserView(model: model)
                .frame(minWidth: 760, minHeight: 560)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1160, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            LeanBrowserCommands(model: model)
        }
    }
}
