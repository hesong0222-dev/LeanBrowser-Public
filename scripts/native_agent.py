#!/usr/bin/env python3
import argparse
import json
import os
import socket
import stat
import sys
import uuid

DEFAULT_SOCKET = os.path.join(os.path.expanduser("~"), ".leanbrowser", "native.sock")
MAX_REQUEST = 64 * 1024
MAX_RESPONSE = 1024 * 1024
MCP_MAX_LINE = 256 * 1024
MCP_PROTOCOL_VERSION = "2024-11-05"

TOOLS = {
    "native_status": ("status", "Read LeanBrowser native-agent availability and browser-control status.", {}),
    "tabs_list": ("tabs.list", "List native tabs and their explicit IDs.", {}),
    "tabs_open": ("tabs.open", "Open an HTTP(S) URL in a native tab. Set select only when foregrounding is intentional.", {"url": {"type": "string"}, "select": {"type": "boolean"}}),
    "browser_snapshot": ("browser.snapshot", "Read a bounded semantic snapshot of one explicit native tab.", {"tabId": {"type": "string"}}),
    "browser_action": ("browser.action", "Perform one click, fill, select, focus, or scroll action against a fresh semantic snapshot reference.", {"tabId": {"type": "string"}, "snapshot": {"type": "string"}, "ref": {"type": "string"}, "action": {"type": "string", "enum": ["click", "fill", "select", "focus", "scroll"]}, "value": {"type": "string"}}),
    "chat_read": ("chat.read", "Read bounded ChatGPT messages and truthful conversation/composer status from one explicit ChatGPT tab.", {"tabId": {"type": "string"}}),
    "chat_send": ("chat.send", "Send text once to one explicit ready ChatGPT tab. Refuses drafts, login gates, generation, and ambiguous controls.", {"tabId": {"type": "string"}, "text": {"type": "string"}}),
    "groups_list": ("groups.list", "List native tab groups.", {}),
}

def call(socket_path, operation, arguments, request_id="cli"):
    if not isinstance(arguments, dict):
        raise ValueError("arguments must be a JSON object")
    request = json.dumps({"id": request_id, "operation": operation, "arguments": arguments}, separators=(",", ":")).encode() + b"\n"
    if len(request) > MAX_REQUEST:
        raise ValueError("request exceeds 64 KiB")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(35)
        client.connect(socket_path)
        client.sendall(request)
        response = bytearray()
        while len(response) <= MAX_RESPONSE:
            piece = client.recv(min(65536, MAX_RESPONSE + 1 - len(response)))
            if not piece:
                break
            response.extend(piece)
            if b"\n" in piece:
                break
    line = bytes(response).split(b"\n", 1)[0]
    if not line or len(line) > MAX_RESPONSE:
        raise RuntimeError("invalid or oversized response")
    parsed = json.loads(line)
    if not isinstance(parsed, dict):
        raise RuntimeError("response must be an object")
    return parsed

def emit(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()

def doctor(socket_path):
    result = {
        "ok": False,
        "command": "doctor",
        "python": {"ok": True, "executable": sys.executable, "version": sys.version.split()[0]},
        "socket": {
            "path": socket_path,
            "exists": False,
            "type": None,
            "mode": None,
            "expected": {"type": "socket", "mode": "0600", "parentMode": "0700"},
            "ok": False,
        },
        "connectivity": {"operation": "status", "ok": False, "message": "not attempted"},
        "messages": [],
    }
    try:
        socket_stat = os.lstat(socket_path)
    except FileNotFoundError:
        result["messages"].append("LeanBrowser is not running or its local socket has not been created; launch the app and retry.")
        return result
    except OSError as error:
        result["messages"].append(f"Cannot inspect native socket: {error}")
        return result

    socket_info = result["socket"]
    socket_info["exists"] = True
    socket_info["type"] = "socket" if stat.S_ISSOCK(socket_stat.st_mode) else "other"
    socket_info["mode"] = format(stat.S_IMODE(socket_stat.st_mode), "04o")
    parent_mode = None
    try:
        parent_mode = format(stat.S_IMODE(os.stat(os.path.dirname(socket_path) or ".").st_mode), "04o")
    except OSError as error:
        result["messages"].append(f"Cannot inspect native socket parent permissions: {error}")
    socket_info["parentMode"] = parent_mode
    socket_info["ok"] = socket_info["type"] == "socket" and socket_info["mode"] == "0600" and parent_mode == "0700"
    if socket_info["type"] != "socket":
        result["messages"].append("Native socket path is not a Unix socket; quit conflicting software and relaunch LeanBrowser.")
        return result
    if not socket_info["ok"]:
        result["messages"].append("Native socket permissions should be 0600 with a 0700 parent directory; relaunch LeanBrowser under this macOS user.")

    try:
        response = call(socket_path, "status", {}, "doctor-" + uuid.uuid4().hex)
        result["connectivity"] = {"operation": "status", "ok": bool(response.get("ok", False)), "response": response}
        if not response.get("ok", False):
            result["messages"].append("LeanBrowser answered status with a refusal; inspect the returned status response and app state.")
    except PermissionError:
        result["connectivity"] = {"operation": "status", "ok": False, "message": "permission denied"}
        result["messages"].append("Permission denied connecting to the native socket; run doctor as the same macOS user that launched LeanBrowser.")
    except OSError as error:
        result["connectivity"] = {"operation": "status", "ok": False, "message": str(error)}
        result["messages"].append("Cannot reach LeanBrowser; confirm the app is running, then retry as the same macOS user.")
    except Exception as error:
        result["connectivity"] = {"operation": "status", "ok": False, "message": str(error)}
        result["messages"].append("Native status returned an invalid response; relaunch LeanBrowser and retry.")
    result["ok"] = bool(result["python"]["ok"] and socket_info["ok"] and result["connectivity"]["ok"])
    return result

def tool_schema(properties, required=()):
    return {"type": "object", "additionalProperties": False, "properties": properties, "required": list(required)}

def mcp_tools():
    tools = []
    for name, (_, description, properties) in TOOLS.items():
        required = [key for key in ("url", "tabId", "text", "snapshot", "ref", "action") if key in properties]
        tools.append({"name": name, "description": description, "inputSchema": tool_schema(properties, required)})
    tools.append({"name": "native_call", "description": "Escape hatch for a documented LeanBrowser native operation not exposed as a dedicated tool.", "inputSchema": tool_schema({"operation": {"type": "string"}, "arguments": {"type": "object"}}, ("operation", "arguments"))})
    return tools

def jsonrpc_error(code, message):
    return {"code": code, "message": message}

def validate_tool_arguments(arguments, properties, required):
    if not isinstance(arguments, dict):
        raise ValueError("tool arguments must be an object")
    unknown = set(arguments) - set(properties)
    missing = set(required) - set(arguments)
    if unknown or missing:
        raise ValueError("invalid tool arguments")
    for key, value in arguments.items():
        expected = properties[key].get("type")
        expected_types = expected if isinstance(expected, list) else [expected]
        valid = ("string" in expected_types and isinstance(value, str)) or ("boolean" in expected_types and isinstance(value, bool)) or ("integer" in expected_types and isinstance(value, int) and not isinstance(value, bool)) or ("object" in expected_types and isinstance(value, dict)) or expected is None
        if not valid or ("enum" in properties[key] and value not in properties[key]["enum"]):
            raise ValueError("invalid tool arguments")
    if arguments.get("action") in {"fill", "select"} and "value" not in arguments:
        raise ValueError("fill and select require a string value")

def read_mcp_frame(stream):
    raw = stream.readline(MCP_MAX_LINE + 1)
    if not raw:
        return None
    size = len(raw) if isinstance(raw, bytes) else len(raw.encode("utf-8"))
    newline = b"\n" if isinstance(raw, bytes) else "\n"
    if size > MCP_MAX_LINE:
        while raw and not raw.endswith(newline):
            raw = stream.readline(MCP_MAX_LINE + 1)
        raise ValueError("JSON-RPC frame exceeds 256 KiB")
    return raw.decode("utf-8") if isinstance(raw, bytes) else raw

def initialize_result(params):
    if not isinstance(params, dict) or not {"protocolVersion", "capabilities", "clientInfo"}.issubset(params):
        raise ValueError("initialize requires protocolVersion, capabilities, and clientInfo")
    client_info = params["clientInfo"]
    if not isinstance(params["protocolVersion"], str) or not isinstance(params["capabilities"], dict) or not isinstance(client_info, dict) or not isinstance(client_info.get("name"), str) or not isinstance(client_info.get("version"), str):
        raise ValueError("invalid initialize request")
    return {"protocolVersion": MCP_PROTOCOL_VERSION, "capabilities": {"tools": {}}, "serverInfo": {"name": "leanbrowser-native", "version": "1.0"}}

def mcp(socket_path):
    stream = getattr(sys.stdin, "buffer", sys.stdin)
    while True:
        message = None
        try:
            raw = read_mcp_frame(stream)
            if raw is None:
                return
            message = json.loads(raw)
            if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or not isinstance(message.get("method"), str):
                raise ValueError("invalid JSON-RPC request")
            method = message.get("method")
            params = message.get("params", {})
            request_id = message.get("id")
            if method == "initialize":
                result = initialize_result(params)
            elif method == "tools/list":
                result = {"tools": mcp_tools()}
            elif method == "ping":
                result = {}
            elif method == "tools/call":
                if not isinstance(params, dict) or not isinstance(params.get("name"), str): raise ValueError("tools/call params must name a tool")
                name, arguments = params["name"], params.get("arguments", {})
                if name == "native_call":
                    validate_tool_arguments(arguments, {"operation": {"type": "string"}, "arguments": {"type": "object"}}, {"operation", "arguments"})
                    operation, native_arguments = arguments["operation"], arguments["arguments"]
                elif name in TOOLS:
                    operation, _, properties = TOOLS[name]
                    required = {key for key in ("url", "tabId", "text", "snapshot", "ref", "action") if key in properties}
                    validate_tool_arguments(arguments, properties, required)
                    native_arguments = arguments
                else:
                    raise LookupError("unknown tool")
                response = call(socket_path, operation, native_arguments, "mcp-" + uuid.uuid4().hex)
                result = {"content": [{"type": "text", "text": json.dumps(response, separators=(",", ":"))}], "isError": not response.get("ok", False)}
            elif method and request_id is None:
                continue
            else:
                raise LookupError("unsupported method")
            if request_id is not None:
                emit({"jsonrpc": "2.0", "id": request_id, "result": result})
        except json.JSONDecodeError:
            emit({"jsonrpc": "2.0", "id": None, "error": jsonrpc_error(-32700, "parse error")})
        except Exception as error:
            if isinstance(message, dict) and message.get("id") is not None:
                code = -32601 if isinstance(error, LookupError) else -32602 if isinstance(error, ValueError) else -32603
                emit({"jsonrpc": "2.0", "id": message["id"], "error": jsonrpc_error(code, str(error))})
            else:
                print(str(error), file=sys.stderr)

def main():
    parser = argparse.ArgumentParser(description="LeanBrowser native local-agent client")
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    parser.add_argument("--mcp", action="store_true")
    parser.add_argument("command", nargs="?")
    parser.add_argument("operation", nargs="?")
    parser.add_argument("arguments", nargs="?")
    args = parser.parse_args()
    if args.mcp:
        mcp(args.socket); return
    if args.command == "doctor":
        report = doctor(args.socket)
        emit(report)
        return 0 if report["ok"] else 1
    if args.command == "status":
        try:
            response = call(args.socket, "status", {}, "status-" + uuid.uuid4().hex)
            emit(response)
            return 0 if response.get("ok") else 1
        except Exception as error:
            print(str(error), file=sys.stderr); return 1
    if args.command == "call" and args.operation:
        try:
            arguments = json.loads(args.arguments or "{}")
            response = call(args.socket, args.operation, arguments, "call-" + uuid.uuid4().hex)
            emit(response)
            return 0 if response.get("ok") else 1
        except Exception as error:
            print(str(error), file=sys.stderr); return 1
    parser.error("use doctor, status, call OP [JSON], or --mcp")

if __name__ == "__main__":
    sys.exit(main())
