import contextlib
import io
import json
import os
import pathlib
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import native_agent


class NativeAgentMCPTests(unittest.TestCase):
    def run_mcp(self, messages, native_response=None):
        output = io.StringIO()
        calls = []

        def fake_call(socket_path, operation, arguments, request_id):
            calls.append((socket_path, operation, arguments, request_id))
            return native_response or {"id": request_id, "ok": True, "result": {"operation": operation}}

        with patch("native_agent.call", fake_call), patch("sys.stdin", io.StringIO(messages)), contextlib.redirect_stdout(output):
            native_agent.mcp("/tmp/leanbrowser-test.sock")
        return [json.loads(line) for line in output.getvalue().splitlines()], calls

    def test_tools_list_advertises_status_chat_and_escape_hatch(self):
        replies, calls = self.run_mcp('{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n')
        names = {tool["name"] for tool in replies[0]["result"]["tools"]}
        self.assertTrue({"native_status", "tabs_list", "tabs_open", "browser_snapshot", "browser_action", "chat_read", "chat_send", "groups_list", "native_call"}.issubset(names))
        self.assertEqual(calls, [])

    def test_native_status_maps_to_empty_status_call(self):
        request = '{"jsonrpc":"2.0","id":"status","method":"tools/call","params":{"name":"native_status","arguments":{}}}\n'
        replies, calls = self.run_mcp(request)
        self.assertFalse(replies[0]["result"]["isError"])
        self.assertEqual(calls[0][1:3], ("status", {}))

    def test_doctor_reports_missing_socket_as_json(self):
        missing = "/tmp/leanbrowser-missing-doctor.sock"
        if os.path.lexists(missing):
            os.unlink(missing)
        report = native_agent.doctor(missing)
        self.assertFalse(report["ok"])
        self.assertFalse(report["socket"]["exists"])
        self.assertFalse(report["connectivity"]["ok"])
        self.assertIn("not running", report["messages"][0])

    def test_doctor_connects_to_a_secure_fake_socket(self):
        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o700)
            path = os.path.join(directory, "native.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            os.chmod(path, 0o600)
            server.listen(1)
            received = []
            def serve():
                client, _ = server.accept()
                with client:
                    received.append(json.loads(client.recv(65536).decode().strip()))
                    client.sendall(b'{"id":"doctor","ok":true,"result":{"browserEnabled":true}}\n')
            worker = threading.Thread(target=serve)
            worker.start()
            try:
                report = native_agent.doctor(path)
            finally:
                worker.join(timeout=2)
                server.close()
            self.assertTrue(report["ok"])
            self.assertTrue(report["socket"]["ok"])
            self.assertTrue(report["connectivity"]["ok"])
            self.assertEqual(received[0]["operation"], "status")
            self.assertEqual(received[0]["arguments"], {})

    def test_chat_send_maps_to_one_explicit_native_call(self):
        request = '{"jsonrpc":"2.0","id":"send","method":"tools/call","params":{"name":"chat_send","arguments":{"tabId":"tab-1","text":"hello"}}}\n'
        replies, calls = self.run_mcp(request)
        self.assertEqual(replies[0]["result"]["isError"], False)
        self.assertEqual(calls[0][1:3], ("chat.send", {"tabId": "tab-1", "text": "hello"}))
        self.assertTrue(calls[0][3].startswith("mcp-"))

    def test_native_refusal_is_an_mcp_error(self):
        request = '{"jsonrpc":"2.0","id":"refused","method":"tools/call","params":{"name":"chat_send","arguments":{"tabId":"tab-1","text":"hello"}}}\n'
        native_response = {"id": "mcp-test", "ok": False, "error": "draft_present", "draftRetained": True, "result": {"error": "draft_present", "draftRetained": True}}
        replies, calls = self.run_mcp(request, native_response)
        self.assertTrue(replies[0]["result"]["isError"])
        self.assertIn("draft_present", replies[0]["result"]["content"][0]["text"])
        self.assertEqual(len(calls), 1)

    def test_invalid_arguments_do_not_reach_native_socket(self):
        request = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_send","arguments":{"tabId":"tab-1"}}}\n'
        replies, calls = self.run_mcp(request)
        self.assertEqual(replies[0]["error"]["code"], -32602)
        self.assertEqual(calls, [])

    def test_initialize_negotiates_explicit_supported_version(self):
        request = '{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"},"_meta":{}}}\n'
        replies, calls = self.run_mcp(request)
        self.assertEqual(replies[0]["result"]["protocolVersion"], native_agent.MCP_PROTOCOL_VERSION)
        self.assertEqual(calls, [])

    def test_browser_action_rejects_unsupported_action_and_missing_fill_value(self):
        unsupported = '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"browser_action","arguments":{"tabId":"t","snapshot":"s","ref":"r","action":"delete"}}}\n'
        missing_value = '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"browser_action","arguments":{"tabId":"t","snapshot":"s","ref":"r","action":"fill"}}}\n'
        replies, calls = self.run_mcp(unsupported + missing_value)
        self.assertEqual([reply["error"]["code"] for reply in replies], [-32602, -32602])
        self.assertEqual(calls, [])

    def test_oversized_frame_is_drained_before_next_request(self):
        oversized = '{"jsonrpc":"2.0","id":5,"method":"ping","params":{"padding":"' + ('x' * native_agent.MCP_MAX_LINE) + '"}}\n'
        ping = '{"jsonrpc":"2.0","id":6,"method":"ping","params":{}}\n'
        replies, calls = self.run_mcp(oversized + ping)
        self.assertEqual(replies, [{"jsonrpc": "2.0", "id": 6, "result": {}}])
        self.assertEqual(calls, [])

    def test_notification_is_silent_and_ping_replies(self):
        requests = '{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":3,"method":"ping"}\n'
        replies, calls = self.run_mcp(requests)
        self.assertEqual(replies, [{"jsonrpc": "2.0", "id": 3, "result": {}}])
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
