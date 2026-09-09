import Foundation
import WebKit

@MainActor
final class SemanticBrowser {
    enum Error: LocalizedError {
        case invalidResult
        case invalidArguments
        case noChatProposal
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidResult: return "semantic_snapshot_invalid"
            case .invalidArguments: return "semantic_action_invalid"
            case .noChatProposal: return "chat_proposal_not_found"
            case .rejected(let value): return value
            }
        }
    }

    static let chatInstructions = """
    To propose LeanBrowser actions, return exactly one fenced JSON object with this strict envelope:
    {\"leanbrowser\":1,\"commands\":[{\"operation\":\"tabs.list\",\"arguments\":{}}]}
    Start with tabs.list or desktop.apps to discover IDs. Browser arguments:
    tabs.open {"url":"https://example.com","select":false}; tabs.close {"tabId":"UUID"}; browser.navigate {"tabId":"UUID","url":"https://example.com"}; browser.wait {"tabId":"UUID","timeoutMs":5000}; browser.snapshot {"tabId":"UUID"}; browser.action {"tabId":"UUID","snapshot":"snapshot from result","ref":"element ref from result","action":"click|fill|select|focus|scroll","value":"required for fill/select"}.
    Tab groups: groups.list {}; groups.create {"name":"Research"}; groups.rename {"groupId":"UUID","name":"New name"}; groups.delete {"groupId":"UUID"}; tabs.group {"tabId":"UUID","groupId":"UUID"}. Use JSON null for groupId to ungroup. Deleting a group keeps its tabs.
    Take a fresh snapshot after every action. Never invent IDs or references. Use only advertised actions. Password/OTP fields cannot be filled. Read results before deciding dependent commands.
    Desktop arguments: desktop.windows {"pid":123}; desktop.snapshot {"pid":123}; desktop.action {"snapshot":"snapshot ID","ref":"element ref","action":"press"}; desktop.setValue {"snapshot":"snapshot ID","ref":"element ref","value":"text"}; desktop.activate {"pid":123}; desktop.key {"pid":123,"key":"enter","modifiers":[]}.
    Desktop operations require the native desktop switch and macOS Accessibility permission. Unsupported app controls may be unavailable. Propose external side effects only when the user explicitly requested them.
    Include at most 8 commands. Supported operations are status, groups.list, groups.create, groups.rename, groups.delete, tabs.group, tabs.list, tabs.open, tabs.close, browser.navigate, browser.snapshot, browser.action, browser.wait, desktop.apps, desktop.windows, desktop.snapshot, desktop.action, desktop.setValue, desktop.activate, and desktop.key. LeanBrowser will validate the schema and show the user a preview before it runs anything. Results are copied back to you by the user; do not claim that a proposal has executed.
    """

    private let world = WKContentWorld.world(name: "LeanBrowserAgent")

    func snapshot(webView: WKWebView, tabID: String, generation: Int) async throws -> [String: Any] {
        let result = try await evaluate(snapshotScript, in: webView, arguments: [
            "tabID": tabID,
            "generation": generation
        ])
        guard let dictionary = result as? [String: Any] else { throw Error.invalidResult }
        return dictionary
    }

    func action(webView: WKWebView, tabID: String, generation: Int, arguments: [String: Any]) async throws -> [String: Any] {
        guard let snapshot = arguments["snapshot"] as? String,
              let ref = arguments["ref"] as? String,
              let operation = arguments["action"] as? String,
              ["click", "fill", "select", "focus", "scroll"].contains(operation) else {
            throw Error.invalidArguments
        }
        var safeArguments: [String: Any] = [
            "tabID": tabID,
            "generation": generation,
            "snapshot": snapshot,
            "ref": ref,
            "action": operation,
            "value": NSNull()
        ]
        if let value = arguments["value"] as? String {
            guard value.count <= 8_192 else { throw Error.invalidArguments }
            safeArguments["value"] = value
        }
        if let value = arguments["value"] as? Int { safeArguments["value"] = value }
        let result = try await evaluate(actionScript, in: webView, arguments: safeArguments)
        guard let dictionary = result as? [String: Any] else { throw Error.invalidResult }
        if let failure = dictionary["error"] as? String { throw Error.rejected(failure) }
        return dictionary
    }

    func chatProposal(webView: WKWebView) async throws -> String {
        let result = try await evaluate(chatProposalScript, in: webView, arguments: [:])
        guard let proposal = result as? String, !proposal.isEmpty else { throw Error.noChatProposal }
        return proposal
    }

    private func evaluate(_ script: String, in webView: WKWebView, arguments: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world) { result in
                continuation.resume(with: result)
            }
        }
    }

    private let snapshotScript = """
    const args = { tabID, generation };
    return (() => {
      const now = Date.now();
      const started = performance.now();
      const state = globalThis.__leanSemanticAgent || (globalThis.__leanSemanticAgent = { snapshots: new Map(), sequence: 0 });
      const clean = value => String(value || '').replace(/\\s+/g, ' ').trim();
      const cut = (value, maximum) => clean(value).slice(0, maximum);
      const visible = element => { const style = element.ownerDocument.defaultView.getComputedStyle(element); return element.getClientRects().length > 0 && style.display !== 'none' && style.visibility !== 'hidden' && !element.closest('[hidden],[aria-hidden="true"]'); };
      const sensitive = element => { const type = (element.getAttribute('type') || '').toLowerCase(); const hint = [element.name, element.id, element.getAttribute('autocomplete'), element.getAttribute('aria-label'), element.placeholder].join(' ').toLowerCase(); return type === 'password' || type === 'file' || /(^|[^a-z])(otp|one.time|verification.?code|security.?code|passcode|password|secret|token|api.?key|recovery.?code|cc.number|cc.csc)([^a-z]|$)/.test(hint); };
      const labelName = element => {
        const ids = (element.getAttribute('aria-labelledby') || '').split(/\\s+/).filter(Boolean);
        const byID = ids.map(id => document.getElementById(id)).filter(Boolean).map(node => node.textContent).join(' ');
        const labels = element.labels ? Array.from(element.labels).map(label => label.textContent).join(' ') : '';
        return cut(element.getAttribute('aria-label') || byID || labels || element.alt || element.placeholder || element.innerText || element.textContent, 240);
      };
      const roleFor = element => {
        const explicit = element.getAttribute('role'); if (explicit) return explicit;
        const tag = element.tagName.toLowerCase();
        if (/^h[1-6]$/.test(tag)) return 'heading'; if (tag === 'a' && element.href) return 'link';
        if (tag === 'button') return 'button'; if (tag === 'select') return 'select'; if (tag === 'textarea') return 'textarea';
        if (tag === 'input') return element.type === 'checkbox' ? 'checkbox' : element.type === 'radio' ? 'radio' : 'input';
        if (element.isContentEditable) return 'textbox'; return 'text';
      };
      const isIncluded = element => { const tag = element.tagName.toLowerCase(); return /^h[1-6]$/.test(tag) || (tag === 'a' && element.href) || ['button','input','select','textarea'].includes(tag) || element.isContentEditable || element.hasAttribute('role'); };
      const elements = [], handles = new Map(), text = [], limitations = [];
      let scanned = 0, stopped = false;
      const inspect = root => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          if (++scanned > 4000 || performance.now() - started > 150 || elements.length >= 400) { stopped = true; return; }
          if (node.nodeType === Node.TEXT_NODE) {
            const parent = node.parentElement;
            if (parent && visible(parent) && !sensitive(parent) && !parent.closest('script,style,noscript,template,[aria-hidden="true"],input,textarea,[contenteditable="true"]')) { const value = cut(node.textContent, 500); if (value) text.push(value); }
            continue;
          }
          const element = node;
          if (!visible(element) || element.closest('[aria-hidden="true"]')) continue;
          if (element.shadowRoot && element.shadowRoot.mode === 'open') inspect(element.shadowRoot);
          if (!isIncluded(element)) continue;
          const ref = 'e' + (++state.sequence);
          const isSensitive = sensitive(element);
          const role = roleFor(element);
          const item = { ref, role, name: isSensitive ? 'Sensitive field' : labelName(element), disabled: !!element.disabled || element.getAttribute('aria-disabled') === 'true', actions: [] };
          if (!isSensitive) {
            if (role === 'input' || role === 'textarea' || role === 'textbox' || role === 'select') item.value = cut(element.value || element.textContent, 1_000);
            if (role === 'link') item.href = cut(element.href, 1_000);
            if (!item.disabled) item.actions = role === 'link' || role === 'button' || role === 'checkbox' || role === 'radio' ? ['click','focus','scroll'] : role === 'select' ? ['select','focus','scroll'] : ['input','textarea','textbox'].includes(role) ? ['fill','focus','scroll'] : ['focus','scroll'];
          } else if (!item.disabled) item.actions = ['focus','scroll'];
          const fingerprint = [role, item.name, element.getAttribute('type') || '', element.href || ''].join('\\u001f');
          handles.set(ref, { element, fingerprint, sensitive: isSensitive });
          elements.push(item);
        }
      };
      inspect(document);
      Array.from(document.querySelectorAll('iframe,frame')).forEach(frame => { try { if (frame.contentDocument) inspect(frame.contentDocument); else limitations.push('cross_origin_frame'); } catch (_) { limitations.push('cross_origin_frame'); } });
      if (stopped) limitations.push('snapshot_budget_reached');
      if (document.querySelector('iframe,frame')) limitations.push('frames_may_be_incomplete');
      const snapshot = crypto.randomUUID();
      const record = { tabID: args.tabID, generation: args.generation, url: location.href, document: document, expires: now + 60_000, handles };
      state.snapshots.clear(); state.snapshots.set(snapshot, record);
      return { snapshot, tabId: args.tabID, generation: args.generation, url: location.href, title: document.title || '', text: cut(text.join(' '), 16_000), elements, truncated: stopped, limitations: Array.from(new Set(limitations)) };
    })()
    """

    private let actionScript = """
    const args = { tabID, generation, snapshot, ref, action, value };
    return (() => {
      const state = globalThis.__leanSemanticAgent;
      const fail = error => ({ error });
      if (!state) return fail('stale_target');
      const record = state.snapshots.get(args.snapshot);
      if (!record || record.expires < Date.now() || record.tabID !== args.tabID || record.generation !== args.generation || record.url !== location.href || record.document !== document) return fail('stale_target');
      const handle = record.handles.get(args.ref);
      if (!handle || !handle.element.isConnected) return fail('stale_target');
      const element = handle.element;
      const role = element.getAttribute('role') || (/^H[1-6]$/.test(element.tagName) ? 'heading' : element.tagName === 'A' ? 'link' : element.tagName === 'BUTTON' ? 'button' : element.tagName === 'SELECT' ? 'select' : element.tagName === 'INPUT' ? element.type === 'checkbox' ? 'checkbox' : element.type === 'radio' ? 'radio' : 'input' : element.isContentEditable ? 'textbox' : element.tagName === 'TEXTAREA' ? 'textarea' : 'input');
      const ids = (element.getAttribute('aria-labelledby') || '').split(/\\s+/).filter(Boolean);
      const labels = element.labels ? Array.from(element.labels).map(label => label.textContent).join(' ') : '';
      const name = handle.sensitive ? 'Sensitive field' : String(element.getAttribute('aria-label') || ids.map(id => document.getElementById(id)).filter(Boolean).map(node => node.textContent).join(' ') || labels || element.alt || element.placeholder || element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 240);
      const fingerprint = [role, name, element.getAttribute('type') || '', element.href || ''].join('\\u001f');
      if (fingerprint !== handle.fingerprint) return fail('stale_target');
      if (element.disabled || element.getAttribute('aria-disabled') === 'true') return fail('disabled_target');
      const sensitive = handle.sensitive || element.type === 'password' || element.type === 'file' || /otp|one.time|verification.?code|security.?code|passcode|password|secret|token|api.?key|recovery.?code|cc.number|cc.csc/i.test([element.name, element.id, element.autocomplete, element.getAttribute('aria-label'), element.placeholder].join(' '));
      if (args.action === 'focus') element.focus({ preventScroll: true });
      else if (args.action === 'scroll') element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
      else if (args.action === 'click') { if (sensitive) return fail('sensitive_target'); element.click(); }
      else if (args.action === 'fill') {
        if (sensitive || element.type === 'hidden') return fail('sensitive_target');
        if (typeof args.value !== 'string' || args.value.length > 8192 || !(/^(INPUT|TEXTAREA)$/.test(element.tagName) || element.isContentEditable)) return fail('invalid_fill');
        if (element.isContentEditable) element.textContent = args.value;
        else { const setter = Object.getOwnPropertyDescriptor(element.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value').set; setter.call(element, args.value); }
        element.dispatchEvent(new Event('input', { bubbles: true })); element.dispatchEvent(new Event('change', { bubbles: true }));
      } else if (args.action === 'select') {
        if (sensitive || element.tagName !== 'SELECT') return fail('invalid_select');
        const value = String(args.value ?? ''); const option = Array.from(element.options).find(option => option.value === value || option.text === value);
        if (!option) return fail('option_not_found'); element.value = option.value; element.dispatchEvent(new Event('input', { bubbles: true })); element.dispatchEvent(new Event('change', { bubbles: true }));
      } else return fail('unsupported_action');
      state.snapshots.clear();
      return { performed: true, action: args.action, ref: args.ref };
    })()
    """

    private let chatProposalScript = """
    return (() => {
      const candidate = node => { const text = (node.textContent || '').trim(); if (text.length > 32 * 1024 || !/^\\s*\\{[\\s\\S]*?\"leanbrowser\"\\s*:\\s*1[\\s\\S]*\\}\\s*$/.test(text)) return ''; return text; };
      const assistant = Array.from(document.querySelectorAll('[data-message-author-role="assistant"]')).reverse();
      for (const message of assistant) for (const node of Array.from(message.querySelectorAll('pre,code')).reverse()) { const value = candidate(node); if (value) return value; }
      for (const node of Array.from(document.querySelectorAll('pre,code')).reverse()) { const value = candidate(node); if (value) return value; }
      return '';
    })()
    """
}
