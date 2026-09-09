# Third-party notices

LeanBrowser 0.6.0-preview.1 contains native Swift source and the optional
`native_agent.py` standard-library client. It does not distribute Electron,
Chromium, Node.js, Python, Go, or third-party Python packages.

The app links against Apple-provided macOS system frameworks including AppKit,
SwiftUI, WebKit, and Security, and is built with the Apple toolchain. Those
components remain subject to their respective Apple license terms and are not
redistributed by this release.

The optional client is intended to run with the user's separately installed
Python 3 interpreter and uses only its standard library. Python is not bundled.

LeanBrowser project source is licensed under the repository's `LICENSE` file.
