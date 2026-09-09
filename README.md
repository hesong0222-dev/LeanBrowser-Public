# LeanBrowser native preview / 네이티브 프리뷰

LeanBrowser is a small macOS browser built with SwiftUI, AppKit, and the
system WKWebView. It has tabs and a bounded local-agent socket for explicit
native-browser actions. It uses **no Electron** and ships **no bundled
Chromium**, so the download stays focused on the native app and your macOS
WebKit runtime.

LeanBrowser는 SwiftUI·AppKit·시스템 WKWebView로 만든 작은 macOS 브라우저입니다.
명시적으로 선택한 탭을 대상으로 제한된 로컬 에이전트 연결을 제공합니다. Electron과
번들 Chromium을 포함하지 않습니다.

## Why LeanBrowser / 주요 기능

- Small native app: system WebKit, lazy background tabs, inactive-tab suspension.
- Project tab groups, drag-to-reorder and group assignment.
- Agent-readable semantic snapshots and explicit tab IDs; actions need no coordinates.
- Background ChatGPT read/send tools with draft protection and uncertain-send safeguards.
- Persistent website sessions and automatic Keychain credential saving for supported submitted forms. Submission is not proof of a successful login; saving can be disabled in Settings.
- Optional desktop accessibility actions behind a session toggle and macOS permission. Web pages do not receive direct computer-control authority.
- Read-only `doctor` diagnostics and a portable MCP skill; no background daemon.

See [release notes](https://github.com/hesong0222-dev/LeanBrowser-Public/releases/tag/v0.6.0-preview.1) for limits and unverified behavior.

## Requirements / 요구 사항

- macOS 14 or later on Apple Silicon (arm64).
- The optional MCP agent kit needs `python3`; the app does not.
- This preview is ad-hoc signed and is **not notarized**.

## Install / 설치

Open the DMG, drag `LeanBrowser.app` to `Applications`, then open it. If
macOS Gatekeeper blocks this unsigned preview, open **System Settings → Privacy
& Security** and choose **Open Anyway** for LeanBrowser after the first launch
attempt. Do not disable Gatekeeper globally and do not use blanket `xattr`
bypass commands.

DMG를 열고 `LeanBrowser.app`을 `Applications`로 드래그하세요. 첫 실행에서
Gatekeeper가 막으면 **시스템 설정 → 개인정보 보호 및 보안**에서 LeanBrowser에 대해
**그래도 열기**를 선택하세요. Gatekeeper를 전역으로 끄거나 광범위한 `xattr` 우회는
사용하지 마세요.

## Optional agent kit / 선택 에이전트 키트

Unzip the agent kit and run:

```sh
./install-agent-kit.sh --dir "$HOME/.local/share/leanbrowser" --skill
```

Add `--codex` only when you want the installer to register the stdio command
with your local Codex CLI. It never starts LeanBrowser or a background daemon.
The installer refuses a conflicting existing destination. Check a running app
with `native_agent.py status`; a connection-refused result means LeanBrowser is
not running or its local agent socket is unavailable.

Codex MCP configuration can also use this template; replace the absolute-path
placeholder before saving:

```toml
[mcp_servers.leanbrowser]
command = "/ABSOLUTE/PATH/TO/python3"
args = ["/ABSOLUTE/PATH/TO/leanbrowser/native_agent.py", "--mcp"]
```

The MCP client communicates only with a running LeanBrowser instance through
its same-user local socket. It does not provide arbitrary shell access,
filesystem access, cookie export, or access to ordinary browser profiles.

## Local checks and source build / 로컬 확인 및 소스 빌드

Use the installed client as a small doctor check:

```sh
python3 "$HOME/.local/share/leanbrowser/native_agent.py" doctor
```

`native_status` in an MCP client reports the same native socket status. A
connection refusal is actionable: open LeanBrowser, then rerun the command.

To build and test source on an Apple Silicon macOS 14+ machine:

```sh
./scripts/build-native.sh /ABSOLUTE/PATH/TO/OUTPUT/DIRECTORY
python3 scripts/test_native_agent_mcp.py
./scripts/package-native-release.sh /ABSOLUTE/PATH/TO/RELEASE/DIRECTORY
```

To uninstall optional tooling, remove the `leanbrowser` MCP entry only if you
created that named entry (for example, `codex mcp remove leanbrowser`), then
explicitly delete the kit directory and/or
`${CODEX_HOME:-$HOME/.codex}/skills/leanbrowser`. This does not delete
LeanBrowser browser data. Remove the app separately in Finder if wanted.

Source and issue tracking: <https://github.com/hesong0222-dev/LeanBrowser-Public>

Preview download: <https://github.com/hesong0222-dev/LeanBrowser-Public/releases/tag/v0.6.0-preview.1>
