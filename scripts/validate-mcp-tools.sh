#!/usr/bin/env bash
# Validate that `allowed-tools` declared in SKILL.md frontmatter match
# the actual tools exposed by the MCP server defined in mcps.json.
#
# Prerequisites:
#   - podman (to run MCP server containers)
#   - A valid KUBECONFIG (e.g., from a Kind cluster)
#   - python3 with PyYAML
#
# Usage:
#   ./scripts/validate-mcp-tools.sh [pack1] [pack2] ...
#   No args: validates all packs that have mcps.json
#   With args: validates only specified packs

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TOTAL_SKILLS=0
PASSED_SKILLS=0
FAILED_SKILLS=0
SKIPPED_SKILLS=0
HAS_ERRORS=false

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}           MCP Tool Validation Report${NC}"
echo -e "${BOLD}    Verifying allowed-tools against live MCP servers${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ -z "${KUBECONFIG:-}" ]; then
  if [ -f "$HOME/.kube/config" ]; then
    export KUBECONFIG="$HOME/.kube/config"
  else
    echo -e "${RED}ERROR: KUBECONFIG not set and ~/.kube/config not found${NC}"
    exit 1
  fi
fi

query_mcp_tools() {
  local command="$1"
  shift
  local args=("$@")

  local expanded_args=()
  for arg in "${args[@]}"; do
    expanded_args+=("$(echo "$arg" | sed "s|\${KUBECONFIG}|${KUBECONFIG}|g")")
  done

  local init_msg='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-tool-validator","version":"0.1"}}}'
  local list_msg='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

  local tools_json
  tools_json=$(
    (echo "$init_msg"; sleep 3; echo "$list_msg"; sleep 3) \
    | "$command" "${expanded_args[@]}" 2>/dev/null \
    | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
        if msg.get('id') == 2:
            tools = msg.get('result', {}).get('tools', [])
            print(json.dumps([t['name'] for t in tools]))
            break
    except json.JSONDecodeError:
        continue
" 2>/dev/null
  ) || true

  echo "$tools_json"
}

extract_allowed_tools() {
  local skill_file="$1"
  python3 -c "
import sys

in_frontmatter = False
for line in open('$skill_file'):
    stripped = line.strip()
    if stripped == '---':
        if not in_frontmatter:
            in_frontmatter = True
            continue
        else:
            break
    if in_frontmatter and stripped.startswith('allowed-tools:'):
        value = stripped[len('allowed-tools:'):].strip()
        if value:
            print(value)
        break
" 2>/dev/null
}

if [ $# -eq 0 ]; then
  PACKS=()
  for mcps_file in "$REPO_ROOT"/*/mcps.json; do
    pack_dir="$(dirname "$mcps_file")"
    pack_name="$(basename "$pack_dir")"
    if [ -d "$pack_dir/skills" ]; then
      PACKS+=("$pack_name")
    fi
  done
else
  PACKS=("$@")
fi

if [ ${#PACKS[@]} -eq 0 ]; then
  echo -e "${BLUE}No packs with mcps.json found${NC}"
  exit 0
fi

echo -e "${BLUE}Packs to validate: ${PACKS[*]}${NC}"
echo ""

EXIT_STATUS=0

for pack in "${PACKS[@]}"; do
  PACK_DIR="$REPO_ROOT/$pack"
  MCPS_FILE="$PACK_DIR/mcps.json"

  if [ ! -f "$MCPS_FILE" ]; then
    echo -e "${YELLOW}⚠️  $pack: mcps.json not found, skipping${NC}"
    continue
  fi

  echo -e "${BOLD}── $pack ──${NC}"

  MCP_SERVERS=$(python3 -c "
import json
with open('$MCPS_FILE') as f:
    cfg = json.load(f)
for name, server in cfg.get('mcpServers', {}).items():
    cmd = server.get('command', '')
    if cmd in ('podman', 'docker'):
        print(name)
" 2>/dev/null)

  declare -A SERVER_TOOLS

  for server_name in $MCP_SERVERS; do
    echo -n "  Starting MCP server '$server_name'... "

    read -r cmd args_json < <(python3 -c "
import json
with open('$MCPS_FILE') as f:
    cfg = json.load(f)
server = cfg['mcpServers']['$server_name']
print(server['command'], json.dumps(server['args']))
" 2>/dev/null)

    mapfile -t args < <(python3 -c "
import json, sys
for a in json.loads(sys.argv[1]):
    print(a)
" "$args_json" 2>/dev/null)

    tools_json=$(query_mcp_tools "$cmd" "${args[@]}")

    if [ -z "$tools_json" ] || [ "$tools_json" = "[]" ]; then
      echo -e "${YELLOW}no tools returned (server may require credentials)${NC}"
      SERVER_TOOLS[$server_name]=""
      continue
    fi

    tool_count=$(python3 -c "import json; print(len(json.loads('$tools_json')))")
    echo -e "${GREEN}$tool_count tools available${NC}"
    SERVER_TOOLS[$server_name]="$tools_json"
  done

  ALL_AVAILABLE_TOOLS=$(python3 -c "
import json
all_tools = set()
$(for sn in $MCP_SERVERS; do
    tools="${SERVER_TOOLS[$sn]:-[]}"
    if [ -n "$tools" ]; then
      echo "all_tools.update(json.loads('$tools'))"
    fi
  done)
print(json.dumps(sorted(all_tools)))
" 2>/dev/null)

  echo -e "  ${BLUE}All available tools: $(python3 -c "import json; print(', '.join(json.loads('$ALL_AVAILABLE_TOOLS')))")${NC}"
  echo ""

  for skill_dir in "$PACK_DIR"/skills/*/; do
    skill_file="$skill_dir/SKILL.md"
    if [ ! -f "$skill_file" ]; then
      continue
    fi

    skill_name="$(basename "$skill_dir")"
    TOTAL_SKILLS=$((TOTAL_SKILLS + 1))

    allowed=$(extract_allowed_tools "$skill_file")

    if [ -z "$allowed" ]; then
      SKIPPED_SKILLS=$((SKIPPED_SKILLS + 1))
      echo -e "  ${YELLOW}⚠️  $pack/$skill_name: no allowed-tools declared, skipping${NC}"
      continue
    fi

    missing=""
    for tool in $allowed; do
      is_present=$(python3 -c "
import json
tools = json.loads('$ALL_AVAILABLE_TOOLS')
print('yes' if '$tool' in tools else 'no')
" 2>/dev/null)
      if [ "$is_present" = "no" ]; then
        missing="$missing $tool"
      fi
    done

    if [ -z "$missing" ]; then
      PASSED_SKILLS=$((PASSED_SKILLS + 1))
      echo -e "  ✅ ${GREEN}$pack/$skill_name${NC}"
    else
      FAILED_SKILLS=$((FAILED_SKILLS + 1))
      HAS_ERRORS=true
      echo -e "  ❌ ${RED}$pack/$skill_name${NC}"
      echo -e "     ${RED}Missing tools:${missing}${NC}"
      echo -e "     ${RED}Declared: $allowed${NC}"
    fi
  done

  unset SERVER_TOOLS
  declare -A SERVER_TOOLS
  echo ""
done

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BOLD}VALIDATION SUMMARY${NC}"
echo "────────────────────────────────────────────────────────────────"
printf "%-42s${BLUE}%s${NC}\n" "Total Skills:" "$TOTAL_SKILLS"
printf "✅ %-39s${GREEN}%s${NC}\n" "Passed:" "$PASSED_SKILLS"
printf "⚠️ %-39s${YELLOW}%s${NC}\n" "Skipped (no allowed-tools):" "$SKIPPED_SKILLS"
printf "❌ %-39s${RED}%s${NC}\n" "Failed:" "$FAILED_SKILLS"
echo ""

if [ "$HAS_ERRORS" = true ]; then
  echo -e "${RED}${BOLD}❌ VALIDATION FAILED - TOOL NAME MISMATCHES DETECTED${NC}"
  echo -e "${RED}Skills declare tools not available in their MCP server.${NC}"
  echo -e "${RED}Check mcps.json for the correct tool names.${NC}"
  EXIT_STATUS=1
elif [ "$SKIPPED_SKILLS" -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}⚠️  PASSED WITH WARNINGS${NC}"
  echo -e "${YELLOW}Some skills have no allowed-tools declaration.${NC}"
else
  echo -e "${GREEN}${BOLD}✅ ALL SKILLS PASSED${NC}"
fi

echo ""
exit $EXIT_STATUS
