#!/bin/bash
set -u

SCRIPT_PATH="${BASH_SOURCE[0]}"

while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_DIR="$(
    cd -P "$(dirname "$SCRIPT_PATH")" && pwd
  )"

  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"

  if [[ "$SCRIPT_PATH" != /* ]]; then
    SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
  fi
done

PLUGIN_DIR="$(
  cd -P "$(dirname "$SCRIPT_PATH")" && pwd
)"

PROJECT_DIR="$(
  cd "$PLUGIN_DIR/.." && pwd
)"

CONNECT_SCRIPT="$PROJECT_DIR/connect.sh"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.sh}"

VPN_HOST=""

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

pid=""

if [[ -n "${VPN_HOST:-}" ]]; then
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue

    process_command="$(
      ps -o command= -p "$candidate_pid" 2>/dev/null || true
    )"

    if [[ "$process_command" == *"$VPN_HOST"* ]]; then
      pid="$candidate_pid"
      break
    fi
  done < <(pgrep -x openconnect 2>/dev/null || true)
fi

if [[ -n "$pid" ]]; then
  etime="$(
    ps -o etime= -p "$pid" 2>/dev/null |
      awk '{$1=$1; print}'
  )"

  echo "🟢 VPN"
  echo "---"
  echo "Status: CONNECTED"
  [[ -n "$etime" ]] && echo "Uptime: $etime"
  echo "To disconnect, press Ctrl+C in the terminal"
else
  echo "⚪️ VPN"
  echo "---"

  if [[ ! -x "$CONNECT_SCRIPT" ]]; then
    echo "Status: CONNECT SCRIPT NOT FOUND"
    echo "$CONNECT_SCRIPT"
  elif [[ ! -r "$CONFIG_FILE" ]]; then
    echo "Status: CONFIG NOT FOUND"
    echo "Create config.sh first"
  elif [[ -z "${VPN_HOST:-}" ]]; then
    echo "Status: VPN_HOST NOT CONFIGURED"
  else
    echo "Status: DISCONNECTED"
    echo "Connect VPN | bash='$CONNECT_SCRIPT' terminal=true refresh=true"
  fi
fi
