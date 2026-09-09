#!/bin/sh
set -eu

usage() {
	cat <<'EOF'
usage: install-agent-kit.sh [--dir ABSOLUTE_PATH] [--codex] [--skill]

Install the LeanBrowser native-agent kit. Python 3 is required for the optional
MCP client; the native macOS app itself has no Python dependency.

  --dir PATH  stable destination (default: ~/.local/share/leanbrowser)
  --codex     register the installed stdio MCP command with the Codex CLI
  --skill     install the packaged LeanBrowser skill under CODEX_HOME/skills
  --help      show this help

Existing destinations are accepted only when every packaged file is byte-for-byte
identical. Conflicting files are never overwritten.
EOF
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_dir="$HOME/.local/share/leanbrowser"
target_dir=$default_dir
register_codex=false
install_skill=false

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dir) [ "$#" -gt 1 ] || { printf '%s\n' '--dir requires an absolute path' >&2; exit 2; }; target_dir=$2; shift 2 ;;
		--codex) register_codex=true; shift ;;
		--skill) install_skill=true; shift ;;
		--help|-h) usage; exit 0 ;;
		*) printf 'unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
	esac
done

case "$target_dir" in /*) ;; *) printf '%s\n' '--dir must be an absolute path' >&2; exit 2 ;; esac
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'python3 is required for the MCP client. Install Python 3, then rerun this installer.' >&2; exit 1; }
[ -f "$script_dir/.leanbrowser-agent-kit.sha256" ] || { printf '%s\n' 'kit manifest is missing; use an official LeanBrowser agent-kit archive' >&2; exit 1; }
kit_files_match() {
	kit_path=$1
	expected_files=$( (awk '{print $2}' "$kit_path/.leanbrowser-agent-kit.sha256"; printf '%s\n' .leanbrowser-agent-kit.sha256) | LC_ALL=C sort)
	actual_files=$(cd "$kit_path" && find . -type f -print | sed 's#^./##' | LC_ALL=C sort)
	[ "$expected_files" = "$actual_files" ]
}
kit_files_match "$script_dir" || { printf '%s\n' 'kit contains files outside its checksum manifest; use an official LeanBrowser agent-kit archive' >&2; exit 1; }
(
	cd "$script_dir"
	shasum -a 256 -c .leanbrowser-agent-kit.sha256 >/dev/null
) || { printf '%s\n' 'kit integrity check failed; download the archive again' >&2; exit 1; }

same_kit=false
if [ -e "$target_dir" ]; then
	[ -d "$target_dir" ] || { printf 'destination exists and is not a directory: %s\n' "$target_dir" >&2; exit 1; }
	if [ -f "$target_dir/.leanbrowser-agent-kit.sha256" ] && cmp -s "$script_dir/.leanbrowser-agent-kit.sha256" "$target_dir/.leanbrowser-agent-kit.sha256" && kit_files_match "$target_dir" && (cd "$target_dir" && shasum -a 256 -c .leanbrowser-agent-kit.sha256 >/dev/null 2>&1); then
		same_kit=true
	else
		printf 'refusing to overwrite conflicting destination: %s\n' "$target_dir" >&2
		exit 1
	fi
fi
if [ "$same_kit" = false ]; then
	mkdir -p "$(dirname -- "$target_dir")"
	ditto "$script_dir" "$target_dir"
	fi

if [ "$install_skill" = true ]; then
	codex_home=${CODEX_HOME:-"$HOME/.codex"}
	skill_target="$codex_home/skills/leanbrowser"
	if [ -e "$skill_target" ]; then
		if [ -d "$skill_target" ] && diff -qr "$target_dir/skills/leanbrowser" "$skill_target" >/dev/null; then :
		else printf 'refusing to overwrite conflicting Codex skill: %s\n' "$skill_target" >&2; exit 1
		fi
	else
		mkdir -p "$codex_home/skills"
		ditto "$target_dir/skills/leanbrowser" "$skill_target"
	fi
fi

if [ "$register_codex" = true ]; then
	command -v codex >/dev/null 2>&1 || { printf '%s\n' 'Codex CLI is required for --codex. Install it or rerun without --codex.' >&2; exit 1; }
	python_bin=$(command -v python3)
	python_bin=$("$python_bin" -c 'import os, sys; print(os.path.realpath(sys.executable))')
	mcp_list=$(codex mcp list --json) || { printf '%s\n' 'could not read Codex MCP configuration; no changes made' >&2; exit 1; }
	entry_present=$(printf '%s' "$mcp_list" | "$python_bin" -c '
import json, sys
items = json.load(sys.stdin)
if not isinstance(items, list):
    raise ValueError("Codex MCP list must be an array")
print("yes" if any(isinstance(item, dict) and item.get("name") == "leanbrowser" for item in items) else "no")
') || { printf '%s\n' 'could not parse Codex MCP configuration; no changes made' >&2; exit 1; }
	if [ "$entry_present" = yes ]; then
		existing=$(codex mcp get leanbrowser --json) || { printf '%s\n' 'could not read existing leanbrowser MCP entry; no changes made' >&2; exit 1; }
		if ! printf '%s' "$existing" | "$python_bin" -c '
import json, sys
value = json.load(sys.stdin)
transport = value.get("transport", {})
command = transport.get("command")
args = transport.get("args")
enabled = value.get("enabled", True)
environment = transport.get("env", {})
cwd = transport.get("cwd", "")
expected_command, expected_args = sys.argv[1:]
if command != expected_command or args != [expected_args, "--mcp"] or enabled is not True or environment not in ({}, None) or cwd not in ("", None):
    raise SystemExit(1)
' "$python_bin" "$target_dir/native_agent.py"; then
			printf '%s\n' 'Codex already has a conflicting leanbrowser MCP entry; refusing to modify it' >&2
			exit 1
		fi
	else
		codex mcp add leanbrowser -- "$python_bin" "$target_dir/native_agent.py" --mcp
	fi
fi
printf 'LeanBrowser agent kit installed at %s\n' "$target_dir"
