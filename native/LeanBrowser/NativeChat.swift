import Foundation
import WebKit

@MainActor
final class NativeChat {
    enum Error: LocalizedError {
        case rejected(String)
        var errorDescription: String? {
            if case let .rejected(value) = self { return value }
            return nil
        }
    }

    private let world = WKContentWorld.world(name: "LeanBrowserNativeChat")

    func read(webView: WKWebView, tabID: String, url: URL) async throws -> [String: Any] {
        try requireSupported(url)
        let result = try await evaluate(readScript, webView: webView, arguments: ["tabID": tabID])
        guard let value = result as? [String: Any] else { throw Error.rejected("chat_read_invalid") }
        if let error = value["error"] as? String { throw Error.rejected(error) }
        return value
    }

    func send(webView: WKWebView, tabID: String, url: URL, text: String) async throws -> [String: Any] {
        try requireSupported(url)
        guard !text.isEmpty, text.count <= 8_192 else { throw Error.rejected("chat_text_required_or_too_long") }
        let result = try await evaluate(sendScript, webView: webView, arguments: ["tabID": tabID, "text": text])
        guard let value = result as? [String: Any] else { throw Error.rejected("chat_send_invalid") }
        if let error = value["error"] as? String, value["retry"] as? Bool != false { throw Error.rejected(error) }
        return value
    }

    private func requireSupported(_ url: URL) throws {
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased()
        guard scheme == "https", host == "chatgpt.com", url.port == nil || url.port == 443 else {
            throw Error.rejected("unsupported_chat_origin")
        }
    }

    private func evaluate(_ script: String, webView: WKWebView, arguments: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world) { result in
                continuation.resume(with: result)
            }
        }
    }

    private let readScript = """
    const args = { tabID };
    return (() => {
      const cut = (value, maximum) => String(value || '').replace(/\\s+/g, ' ').trim().slice(0, maximum);
      const visible = node => { const style = getComputedStyle(node); return node.getClientRects().length > 0 && style.display !== 'none' && style.visibility !== 'hidden'; };
      const hostOK = location.protocol === 'https:' && location.hostname === 'chatgpt.com' && (location.port === '' || location.port === '443');
      if (!hostOK) return { error: 'unsupported_chat_host' };
      const fallbackOrdinals = {};
      const messages = Array.from(document.querySelectorAll('[data-message-author-role]')).filter(visible).map((node) => {
        const role = node.getAttribute('data-message-author-role') || 'unknown';
        const text = cut(node.innerText || node.textContent, 6000);
        const messageID = node.getAttribute('data-message-id') || node.id;
        const rawID = messageID || `${role}:${text}`;
        const fallbackOrdinal = messageID ? 0 : (fallbackOrdinals[rawID] = (fallbackOrdinals[rawID] || 0) + 1);
        let hash = 2166136261; for (let i = 0; i < rawID.length; i++) hash = Math.imul(hash ^ rawID.charCodeAt(i), 16777619);
        return { id: `chat-${(hash >>> 0).toString(36)}${fallbackOrdinal ? `-${fallbackOrdinal}` : ''}`, role, text, truncated: text.length >= 6000 };
      }).filter(message => message.text).slice(-60);
      let extractionMode = 'data_message_author_role';
      if (messages.length === 0) {
        const region = Array.from(document.querySelectorAll('[role="region"][aria-label="Conversation"]')).find(visible);
        if (region) {
          const headings = Array.from(region.querySelectorAll('h1, h2, h3, h4, h5, h6, [role="heading"]')).filter(visible).map(node => ({ node, label: cut(node.innerText || node.textContent, 80).toLowerCase() })).filter(item => item.label === 'you said:' || item.label === 'chatgpt said:');
          const fallbackOrdinals = {};
          const fallbackMessages = headings.map((item) => {
            const turn = item.node.closest('[data-turn-id], article, li') || item.node.parentElement;
            if (!turn || !region.contains(turn)) return null;
            const range = document.createRange();
            range.setStartAfter(item.node);
            range.setEndAfter(turn.lastChild);
            const text = cut(range.cloneContents().textContent, 6000);
            const role = item.label === 'you said:' ? 'user' : 'assistant';
            const rawID = `${role}:${text}`;
            const ordinal = fallbackOrdinals[rawID] = (fallbackOrdinals[rawID] || 0) + 1;
            let hash = 2166136261; for (let i = 0; i < rawID.length; i++) hash = Math.imul(hash ^ rawID.charCodeAt(i), 16777619);
            return { id: `chat-${(hash >>> 0).toString(36)}-${ordinal}`, role, text, truncated: text.length >= 6000, extraction: 'heading_fallback' };
          }).filter(message => message && message.text).slice(-60);
          if (fallbackMessages.length) { messages.push(...fallbackMessages); extractionMode = 'anonymous_conversation_heading_fallback'; }
        }
      }
      const composer = Array.from(document.querySelectorAll('#prompt-textarea, textarea[data-testid="prompt-textarea"], textarea[aria-label="Chat with ChatGPT"], [contenteditable="true"][data-id="root"], [contenteditable="true"][aria-label*="Chat with ChatGPT"]')).filter(visible);
      const draftPresent = composer.length === 1 && String(composer[0].value ?? composer[0].innerText ?? composer[0].textContent ?? '').length > 0;
      const login = /(^|\\s)(log in|sign in)(\\s|$)/i.test(document.body?.innerText || '') && composer.length === 0;
      const generating = Array.from(document.querySelectorAll('[data-testid="stop-button"], button[aria-label*="Stop"]')).some(visible);
      return { tabId: args.tabID, provider: 'chatgpt', conversation: { id: location.pathname.split('/').filter(Boolean).pop() || null, url: location.href }, messages, messageCount: messages.length, extractionMode, status: { generating, busy: generating, loginRequired: login, composer: composer.length === 1 ? 'ready' : composer.length === 0 ? 'missing' : 'ambiguous', draftPresent } };
    })()
    """

    private let sendScript = """
    const args = { tabID, text };
    return (async () => {
      const visible = node => { const style = getComputedStyle(node); return node.getClientRects().length > 0 && style.display !== 'none' && style.visibility !== 'hidden'; };
      const hostOK = location.protocol === 'https:' && location.hostname === 'chatgpt.com' && (location.port === '' || location.port === '443');
      if (!hostOK) return { error: 'unsupported_chat_host' };
      const composer = Array.from(document.querySelectorAll('#prompt-textarea, textarea[data-testid="prompt-textarea"], textarea[aria-label="Chat with ChatGPT"], [contenteditable="true"][data-id="root"], [contenteditable="true"][aria-label*="Chat with ChatGPT"]')).filter(visible);
      if (composer.length === 0) return { error: /log in|sign in/i.test(document.body?.innerText || '') ? 'login_required' : 'composer_missing' };
      if (composer.length !== 1) return { error: 'ambiguous_composer' };
      if (Array.from(document.querySelectorAll('[data-testid="stop-button"], button[aria-label*="Stop"]')).some(visible)) return { error: 'chat_generating' };
      const field = composer[0], rawDraft = String(field.value ?? field.innerText ?? field.textContent ?? '');
      if (rawDraft.length > 0) return { error: 'draft_present' };
      if (field.isContentEditable) field.textContent = args.text;
      else { const prototype = field.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype; Object.getOwnPropertyDescriptor(prototype, 'value').set.call(field, args.text); }
      field.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: args.text }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
      const deadline = Date.now() + 2000;
      let buttons = [];
      do {
        buttons = Array.from(document.querySelectorAll('button[data-testid="send-button"], button[aria-label="Send prompt"], button[aria-label="Send message"]')).filter(button => visible(button) && !button.disabled && button.getAttribute('aria-disabled') !== 'true');
        if (buttons.length === 1) break;
        await new Promise(resolve => setTimeout(resolve, 50));
      } while (Date.now() < deadline);
      const currentComposer = Array.from(document.querySelectorAll('#prompt-textarea, textarea[data-testid="prompt-textarea"], textarea[aria-label="Chat with ChatGPT"], [contenteditable="true"][data-id="root"], [contenteditable="true"][aria-label*="Chat with ChatGPT"]')).filter(visible);
      const currentDraft = String(field.value ?? field.innerText ?? field.textContent ?? '');
      const generating = Array.from(document.querySelectorAll('[data-testid="stop-button"], button[aria-label*="Stop"]')).some(visible);
      if (currentComposer.length !== 1 || currentComposer[0] !== field || !field.isConnected || currentDraft !== args.text || generating) return { error: 'composer_changed_before_dispatch', draftRetained: currentDraft.length > 0, retry: false, status: 'not_dispatched' };
      if (buttons.length !== 1) return { error: buttons.length ? 'ambiguous_send_control' : 'send_control_unavailable', draftRetained: currentDraft.length > 0, retry: false, status: 'not_dispatched' };
      buttons[0].click();
      return { tabId: args.tabID, provider: 'chatgpt', status: 'dispatched', dispatched: true, sent: false, retry: false };
    })()
    """
}
