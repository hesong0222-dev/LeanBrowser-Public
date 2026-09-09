import Foundation
import WebKit

@MainActor
final class CredentialBridge: NSObject, WKScriptMessageHandler {
    private weak var tab: BrowserTab?
    private weak var webView: WKWebView?
    private let handlerName: String
    private let world: WKContentWorld

    init(tab: BrowserTab) {
        self.tab = tab
        handlerName = "leanCredential_\(tab.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        world = WKContentWorld.world(name: "LeanBrowserCredentials.\(tab.id.uuidString)")
    }

    func install(on webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: world, name: handlerName)
        controller.addUserScript(WKUserScript(source: captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        self.webView = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == handlerName,
              let tab, let webView, message.webView === webView,
              message.frameInfo.isMainFrame,
              tab.model?.saveCredentials == true,
              let origin = CredentialOrigin(scheme: message.frameInfo.securityOrigin.protocol, host: message.frameInfo.securityOrigin.host, port: message.frameInfo.securityOrigin.port == 0 ? nil : Int(message.frameInfo.securityOrigin.port)),
              let currentURL = webView.url, let current = CredentialOrigin(url: currentURL), current == origin,
              let payload = message.body as? [String: Any],
              let username = payload["username"] as? String,
              let password = payload["password"] as? String,
              username.count <= 1_024, password.count <= 4_096,
              !username.isEmpty, !password.isEmpty else { return }
        do {
            try tab.model?.credentialStore.upsert(SubmittedCredential(username: username, password: password), for: origin)
            tab.model?.noteCredentialSubmissionSaved()
        } catch {
            tab.model?.noteCredentialSubmissionNotSaved()
        }
    }

    func fillSavedCredential() async -> Bool {
        guard let tab, let webView, tab.model?.saveCredentials == true,
              tab.webViewIfLoaded === webView,
              let currentURL = webView.url, let origin = CredentialOrigin(url: currentURL),
              let credential = try? tab.model?.credentialStore.credential(for: origin) else { return false }
        let generation = tab.navigationGeneration
        guard tab.webViewIfLoaded === webView, tab.navigationGeneration == generation,
              tab.model?.saveCredentials == true, webView.url.flatMap({ CredentialOrigin(url: $0) }) == origin else { return false }
        let result: Result<Any, Error> = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(Self.fillScript, arguments: ["username": credential.username, "password": credential.password, "expectedOrigin": origin.canonical], in: nil, in: world) {
                continuation.resume(returning: $0)
            }
        }
        guard case .success(let value) = result, value as? Bool == true,
              tab.webViewIfLoaded === webView, tab.navigationGeneration == generation,
              tab.model?.saveCredentials == true, webView.url.flatMap({ CredentialOrigin(url: $0) }) == origin else { return false }
        tab.model?.noteCredentialFilled()
        return true
    }

    private var captureScript: String {
        """
        (() => {
          const post = (form) => {
            if (!(form instanceof HTMLFormElement)) return;
            const fields = Array.from(form.elements).filter(e => e instanceof HTMLInputElement && !e.disabled && e.type !== 'hidden');
            const passwordFields = fields.filter(e => e.type === 'password');
            const current = passwordFields.find(e => e.autocomplete === 'current-password') || passwordFields.find(e => e.autocomplete === 'new-password') || passwordFields[0];
            if (!current || !current.value) return;
            const confirmations = passwordFields.filter(e => e !== current && (e.autocomplete === 'new-password' || /confirm|repeat|verify/i.test([e.name,e.id,e.placeholder,e.getAttribute('aria-label')].join(' '))));
            if ((current.autocomplete === 'new-password' || passwordFields.length > 1) && confirmations.length && confirmations.some(e => e.value !== current.value)) return;
            const username = fields.find(e => /^(username|email)$/i.test(e.autocomplete || '')) || fields.find(e => /email|user|login|account/i.test([e.name,e.id,e.placeholder,e.getAttribute('aria-label')].join(' ')) && e.type !== 'password');
            if (!username || !username.value) return;
            const submittedUsername = String(username.value);
            const submittedPassword = String(current.value);
            if (submittedUsername.length > 1024 || submittedPassword.length > 4096) return;
            window.webkit.messageHandlers['\(handlerName)'].postMessage({username: submittedUsername, password: submittedPassword});
          };
          document.addEventListener('submit', event => { if (event.isTrusted) post(event.target); }, true);
        })();
        """
    }

    private static let fillScript = """
    return (() => {
      const rawHost = location.hostname.toLowerCase();
      const host = rawHost.startsWith('[') && rawHost.endsWith(']') ? rawHost.slice(1, -1) : rawHost;
      const printableHost = host.includes(':') ? '[' + host + ']' : host;
      const port = location.port || (location.protocol === 'https:' ? '443' : location.protocol === 'http:' ? '80' : '');
      if (!port || location.protocol + String.fromCharCode(47, 47) + printableHost + ':' + port !== expectedOrigin) return false;
      const visible = e => e instanceof HTMLInputElement && !e.disabled && e.type !== 'hidden' && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden' && getComputedStyle(e).display !== 'none';
      const fields = Array.from(document.querySelectorAll('input')).filter(visible);
      const usernameField = fields.find(e => /^(username|email)$/i.test(e.autocomplete || '')) || fields.find(e => e.type !== 'password' && /email|user|login|account/i.test([e.name,e.id,e.placeholder,e.getAttribute('aria-label')].join(' ')));
      const passwordField = fields.find(e => e.type === 'password' && e.autocomplete === 'current-password');
      if (!usernameField || !passwordField) return false;
      const set = (element, value) => { const descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value'); descriptor.set.call(element, value); element.dispatchEvent(new Event('input', {bubbles:true})); element.dispatchEvent(new Event('change', {bubbles:true})); };
      set(usernameField, username); set(passwordField, password); return true;
    })()
    """
}
