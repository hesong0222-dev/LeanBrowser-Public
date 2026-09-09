# LeanBrowser protocol reference

The native bridge is a same-UID local Unix socket. The stable optional client path is `~/.local/share/leanbrowser/native_agent.py`:

```sh
python3 ~/.local/share/leanbrowser/native_agent.py doctor
python3 ~/.local/share/leanbrowser/native_agent.py --mcp
python3 ~/.local/share/leanbrowser/native_agent.py call tabs.list '{}'
```

Native calls are one newline-delimited JSON request and response:

```json
{"id":"req-1","operation":"status","arguments":{}}
{"id":"req-1","ok":true,"result":{}}
```

Core operations are `status`, `tabs.list/open/close/group`, `groups.list/create/rename/delete`, `browser.navigate/wait/snapshot/action`, `chat.read/send`, `desktop.apps/windows/snapshot/action/setValue/activate/key`, and bounded `job.submit/list/get/cancel`. Browser targets require an explicit `tabId`. There are at most 32 tabs and 32 named groups. Group schemas:

```json
{"operation":"groups.create","arguments":{"name":"Research"}}
{"operation":"tabs.group","arguments":{"tabId":"TAB_ID","groupId":"GROUP_ID"}}
{"operation":"tabs.group","arguments":{"tabId":"TAB_ID","groupId":null}}
```

Names are at most 80 characters; deleting a group ungroups its tabs. `inspect_window` is unsupported. The native transport bounds requests to 64 KiB, responses to 1 MiB, allows four pending clients, and uses roughly five-second read and 30-second completion deadlines. A timeout is `outcome_unknown`; inspect before any new mutation.

The MCP bridge exposes the dedicated `native_status` tool and discoverable tools such as `tabs_list`, `tabs_open`, `browser_snapshot`, `browser_action`, `chat_read`, `chat_send`, and `groups_list`, plus `native_call(operation, arguments)`. Call `native_status` first. Use the installed schemas; do not fabricate tool names or arguments.

## ChatGPT-specific flow

`chat.read` and `chat.send` require an explicit tab whose current origin is exactly `https://chatgpt.com` (HTTPS default port). `chat.send` takes `{"tabId":"TAB_ID","text":"..."}` (maximum 8,192 characters). Read status, ensure no draft, no active generation, one stable composer and an unambiguous send control, send once, then read refreshed messages/status. A result of `dispatched` proves only that the click was issued; it proves neither provider acceptance nor completion. Existing drafts, ambiguous controls, timeouts, or disconnects require preserving state and no automatic retry. Preserve the user-selected Chat/Work mode; when Chat-only is requested, never switch to Work.

## Desktop and evidence limits

Desktop operations need the native current-session toggle and macOS Accessibility permission. Use short-lived semantic AX snapshots and defined actions only; secure fields remain protected. There is no arbitrary JavaScript, selector, coordinate, shell, filesystem, remote listener, cookie extraction, or webpage socket authority. Persistent `WKWebsiteDataStore` presence does not prove authenticated third-party persistence. Protocol fixture checks prove rejection/transport behavior only; record live provider and AX outcomes separately.
