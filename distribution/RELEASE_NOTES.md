# LeanBrowser 0.6.0-preview.1

Native macOS 14+ browser for people and local agents. This preview binary targets Apple Silicon (arm64); Intel users can build from source on an Intel Mac, but that build has not been verified for this release.

## Included

- Native SwiftUI/AppKit UI and system WKWebView: no bundled Chromium, Electron, Node runtime, or background automation daemon.
- Persistent browser-owned website storage, tab groups, drag-to-reorder/group tabs, lazy background web views, and bounded inactive-tab suspension.
- Same-user local Unix socket and optional Python standard-library MCP stdio bridge.
- Semantic snapshots and fresh element references for actions, explicit tab IDs, and background ChatGPT read/send tools.
- Native status discovery and a read-only connection doctor.
- Portable LeanBrowser agent skill and installer for the MCP kit.

## Boundaries

This is an ad-hoc signed, **not notarized** preview. macOS may block first launch; see the installation README. No Developer ID trust or App Store approval is claimed.

Passwords are saved on supported submitted login/signup forms by default in the browser's macOS Keychain service. This detects submission, not successful authentication. Disable saving or delete stored entries in the app settings. MCP cannot export passwords or cookies. Persistent storage does not guarantee every provider keeps a login valid.

Desktop control requires the native session toggle and macOS Accessibility permission. Web chat responses do not gain direct authority over the computer. Chat sending does not itself prove provider acceptance; read the conversation afterward and do not blindly retry uncertain sends.

The app has one native window with up to 32 tabs and 32 groups. Chat-specific tools currently target HTTPS ChatGPT pages. Site changes can affect semantic extraction and composer detection. This release makes no measured RAM comparison or production reliability claim.
