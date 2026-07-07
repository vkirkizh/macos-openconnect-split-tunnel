#!/bin/bash
set -euo pipefail
echo -ne '\033]0;OpenConnect VPN\007'

echo "Initializing..."

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"

CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.sh}"

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE"
  echo "Copy config.example.sh to config.sh and edit it."
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

NODE_MODULES_ROOT=""
CHROME_PID=""
OPENCONNECT_PID=""
TAIL_PID=""
SUDO_KEEPALIVE_PID=""
JS_FILE=""
LOG_FILE=""
VPNC_WRAPPER_FILE=""
VPNC_SCRIPT=""
VPN_GATEWAY=""
CLEANUP_DONE=0
DNS_CONFIGURED=0

VPN_ADDED_NETWORKS=()

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 not found"
    exit 1
  }
}

require_value() {
  local name="$1"
  local value="${2:-}"

  if [[ -z "$value" ]]; then
    echo "Required config value is empty: $name"
    exit 1
  fi
}

validate_network_entries() {
  local entry
  local network
  local displayed_route
  local test_ip
  local extra

  for entry in "${VPN_ALLOWED_NETWORKS[@]}"; do
    if [[ "$entry" == *" "* ]]; then
      echo "Invalid VPN_ALLOWED_NETWORKS entry: $entry"
      echo "Spaces are not allowed in network entries"
      exit 1
    fi

    IFS='|' read -r network displayed_route test_ip extra <<< "$entry"

    if [[ -z "$network" ||
          -z "$displayed_route" ||
          -z "$test_ip" ||
          -n "${extra:-}" ]]; then
      echo "Invalid VPN_ALLOWED_NETWORKS entry: $entry"
      echo "Expected format: canonical-CIDR|netstat-route|test-IP"
      exit 1
    fi
  done
}

add_allowed_network_routes() {
  local entry
  local network
  local displayed_route
  local test_ip
  local current_gateway

  for entry in "${VPN_ALLOWED_NETWORKS[@]}"; do
    IFS='|' read -r network displayed_route test_ip <<< "$entry"

    current_gateway="$(
      route -n get "$test_ip" 2>/dev/null |
        awk '/gateway:/ { print $2; exit }' ||
        true
    )"

    if [[ "$current_gateway" == "$VPN_GATEWAY" ]]; then
      echo "Route already exists: $network"
      continue
    fi

    if sudo route -n add -net "$network" "$VPN_GATEWAY" \
      >/dev/null 2>&1; then
      VPN_ADDED_NETWORKS+=("$network")
      echo "Route added: $network"
    else
      echo "Cannot configure route $network via $VPN_GATEWAY"
      return 1
    fi
  done
}

validate_allowed_network_routes() {
  local entry
  local network
  local displayed_route
  local test_ip
  local actual_gateway

  for entry in "${VPN_ALLOWED_NETWORKS[@]}"; do
    IFS='|' read -r network displayed_route test_ip <<< "$entry"

    actual_gateway="$(
      route -n get "$test_ip" 2>/dev/null |
        awk '/gateway:/ { print $2; exit }' ||
        true
    )"

    if [[ "$actual_gateway" != "$VPN_GATEWAY" ]]; then
      echo "Invalid route for $network"
      echo "Expected gateway: $VPN_GATEWAY"
      echo "Actual gateway: ${actual_gateway:-not found}"
      return 1
    fi
  done
}

need sudo
need node
need npm
need openconnect
need lsof
need tail
need netstat
need awk
need route
need curl
need mkdir
need rm
need chmod
need tee
need dscacheutil
need killall
need mktemp
need sleep
need grep

require_value "CHROME_BIN" "${CHROME_BIN:-}"
require_value "CHROME_PROFILE_DIR" "${CHROME_PROFILE_DIR:-}"
require_value "CDP_PORT" "${CDP_PORT:-}"
require_value "VPN_HOST" "${VPN_HOST:-}"
require_value "COOKIE_NAME" "${COOKIE_NAME:-}"
require_value "VPN_CORPORATE_DNS" "${VPN_CORPORATE_DNS:-}"
require_value "VPN_GATEWAY_REGEX" "${VPN_GATEWAY_REGEX:-}"

if ! declare -p VPN_ALLOWED_NETWORKS 2>/dev/null |
     grep -q '^declare -a '; then
  echo "VPN_ALLOWED_NETWORKS must be an indexed array"
  exit 1
fi

if (( ${#VPN_ALLOWED_NETWORKS[@]} == 0 )); then
  echo "VPN_ALLOWED_NETWORKS must contain at least one network"
  exit 1
fi

if ! declare -p CORPORATE_DNS_DOMAINS 2>/dev/null |
     grep -q '^declare -a '; then
  echo "CORPORATE_DNS_DOMAINS must be an indexed array"
  exit 1
fi

if (( ${#CORPORATE_DNS_DOMAINS[@]} == 0 )); then
  echo "CORPORATE_DNS_DOMAINS must contain at least one domain"
  exit 1
fi

validate_network_entries

if ! [[ "${VPN_ROUTE_SETUP_DELAY_SECONDS:-3}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "VPN_ROUTE_SETUP_DELAY_SECONDS must be a non-negative number"
  exit 1
fi

NODE_MODULES_ROOT="$(npm root -g)"
export NODE_PATH="${NODE_MODULES_ROOT}:${NODE_PATH:-}"

node -e "require('playwright');" >/dev/null 2>&1 || {
  echo "Playwright not found. Install it with:"
  echo "  npm install -g playwright"
  exit 1
}

[[ -x "$CHROME_BIN" ]] || {
  echo "Google Chrome not found at: $CHROME_BIN"
  exit 1
}

mkdir -p "$CHROME_PROFILE_DIR"
LOG_FILE="$(mktemp /tmp/openconnect_split_tunnel.XXXXXX.log)"

cleanup() {
  local exit_code=$?
  local i

  if (( CLEANUP_DONE )); then
    return
  fi

  CLEANUP_DONE=1

  echo
  echo "Finishing processes..."

  if [[ -n "${TAIL_PID:-}" ]]; then
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
    TAIL_PID=""
  fi

  if [[ -n "${VPN_GATEWAY:-}" ]]; then
    for (( i=${#VPN_ADDED_NETWORKS[@]}-1; i>=0; i-- )); do
      sudo route -n delete -net \
        "${VPN_ADDED_NETWORKS[$i]}" \
        "$VPN_GATEWAY" \
        >/dev/null 2>&1 || true
    done
  fi

  VPN_ADDED_NETWORKS=()

  if [[ -n "${OPENCONNECT_PID:-}" ]]; then
    kill -SIGINT "$OPENCONNECT_PID" 2>/dev/null || true
    wait "$OPENCONNECT_PID" 2>/dev/null || true
    OPENCONNECT_PID=""
  fi

  if (( DNS_CONFIGURED )); then
    echo "Removing split DNS..."

    for domain in "${CORPORATE_DNS_DOMAINS[@]}"; do
      sudo rm -f "/etc/resolver/$domain" 2>/dev/null || true
    done

    sudo dscacheutil -flushcache 2>/dev/null || true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    DNS_CONFIGURED=0
  fi

  if [[ -n "${CHROME_PID:-}" ]]; then
    kill "$CHROME_PID" 2>/dev/null || true
    wait "$CHROME_PID" 2>/dev/null || true
    CHROME_PID=""
  fi

  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi

  rm -f "${LOG_FILE:-}" 2>/dev/null || true
  rm -f "${JS_FILE:-}" 2>/dev/null || true
  rm -f "${VPNC_WRAPPER_FILE:-}" 2>/dev/null || true

  if (( exit_code == 0 )); then
    echo "Finished."
  elif (( exit_code == 130 || exit_code == 143 )); then
    echo "Stopped."
  else
    echo "Finished with error, exit code: $exit_code"
  fi
}

trap cleanup EXIT
trap 'exit 130' SIGINT
trap 'exit 143' SIGTERM

sudo -v

if lsof -iTCP:"$CDP_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $CDP_PORT is busy"
  exit 1
fi

"$CHROME_BIN" \
  --remote-debugging-port="${CDP_PORT}" \
  --remote-debugging-address=127.0.0.1 \
  --user-data-dir="${CHROME_PROFILE_DIR}" \
  "https://${VPN_HOST}/+CSCOE+/logon.html" \
  >/dev/null 2>&1 &

CHROME_PID=$!

for _ in {1..40}; do
  if curl -fsS \
    "http://127.0.0.1:${CDP_PORT}/json/version" \
    >/dev/null 2>&1; then
    break
  fi

  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    echo "Chrome terminated unexpectedly"
    exit 1
  fi

  sleep 0.25
done

if ! curl -fsS \
  "http://127.0.0.1:${CDP_PORT}/json/version" \
  >/dev/null 2>&1; then
  echo "Cannot start Chrome with CDP"
  exit 1
fi

echo
echo "Waiting for SSO in browser..."

JS_FILE="$(mktemp /tmp/openconnect_cdp.XXXXXX.cjs)"

cat > "$JS_FILE" <<'JS'
const { chromium } = require("playwright");

(async () => {
  const cdpAddress = process.env.CDP_ADDR;
  const vpnAddress = process.env.VPN_ADDR;
  const cookieName = process.env.COOKIE_NAME;

  const browser = await chromium.connectOverCDP(cdpAddress);
  const contexts = browser.contexts();
  const context = contexts[0] || await browser.newContext();

  let value = null;

  for (let i = 0; i < 1000; i++) {
    const cookies = await context.cookies(vpnAddress);
    const cookie = cookies.find((item) => item.name === cookieName);

    if (cookie && cookie.value) {
      value = cookie.value;
      break;
    }

    await new Promise((resolve) => setTimeout(resolve, 1000));
  }

  await browser.close();

  if (!value) {
    console.error("Cannot get VPN cookie");
    process.exit(1);
  }

  process.stdout.write(value);
})();
JS

COOKIE="$(
  CDP_ADDR="http://127.0.0.1:${CDP_PORT}" \
  VPN_ADDR="https://${VPN_HOST}" \
  COOKIE_NAME="${COOKIE_NAME}" \
  node "$JS_FILE"
)"

if [[ -z "$COOKIE" ]]; then
  echo "Received an empty VPN cookie"
  exit 1
fi

if [[ -n "${CHROME_PID:-}" ]]; then
  kill "$CHROME_PID" 2>/dev/null || true
  wait "$CHROME_PID" 2>/dev/null || true
  CHROME_PID=""
fi

sudo -v

while true; do
  sudo -n -v 2>/dev/null || exit
  sleep 60
done &

SUDO_KEEPALIVE_PID=$!

for candidate in \
  "/opt/homebrew/etc/vpnc/vpnc-script" \
  "/usr/local/etc/vpnc/vpnc-script" \
  "/etc/vpnc/vpnc-script"
do
  if [[ -x "$candidate" ]]; then
    VPNC_SCRIPT="$candidate"
    break
  fi
done

if [[ -z "$VPNC_SCRIPT" ]]; then
  echo "vpnc-script not found"
  exit 1
fi

VPNC_WRAPPER_FILE="$(mktemp /tmp/openconnect_vpnc_wrapper.XXXXXX.sh)"

cat > "$VPNC_WRAPPER_FILE" <<EOF_WRAPPER
#!/bin/sh

unset INTERNAL_IP4_DNS
unset INTERNAL_IP6_DNS
unset CISCO_SPLIT_DNS
unset CISCO_DEF_DOMAIN

exec "$VPNC_SCRIPT" "\$@"
EOF_WRAPPER

chmod 700 "$VPNC_WRAPPER_FILE"

# The log file belongs to the current user; only OpenConnect needs sudo.
# shellcheck disable=SC2024
sudo openconnect \
  --cookie "$COOKIE" \
  --no-dtls \
  --script "$VPNC_WRAPPER_FILE" \
  "$VPN_HOST" \
  > "$LOG_FILE" 2>&1 &

OPENCONNECT_PID=$!
unset COOKIE

tail -n +1 -F "$LOG_FILE" &
TAIL_PID=$!

sleep 1

if ! kill -0 "$OPENCONNECT_PID" 2>/dev/null; then
  echo
  echo "OpenConnect failed to start"

  wait "$OPENCONNECT_PID" 2>/dev/null || true
  OPENCONNECT_PID=""
  exit 1
fi

echo
echo "Waiting for VPN gateway..."

for _ in {1..20}; do
  if ! kill -0 "$OPENCONNECT_PID" 2>/dev/null; then
    echo "OpenConnect terminated while waiting for VPN gateway"

    wait "$OPENCONNECT_PID" 2>/dev/null || true
    OPENCONNECT_PID=""
    exit 1
  fi

  VPN_GATEWAY="$(
    netstat -rn -f inet |
      awk -v regex="$VPN_GATEWAY_REGEX" '$2 ~ regex { print $2; exit }' ||
      true
  )"

  if [[ -n "$VPN_GATEWAY" ]]; then
    echo "VPN gateway found: $VPN_GATEWAY"
    break
  fi

  sleep 1
done

if [[ -z "$VPN_GATEWAY" ]]; then
  echo "VPN gateway not found"
  exit 1
fi

sleep "${VPN_ROUTE_SETUP_DELAY_SECONDS:-3}"

VPN_INTERFACE_PREFIX="$(
  awk -F. '{ print $1 "." $2 "." $3 }' <<< "$VPN_GATEWAY"
)"

VPN_INTERFACE_ROUTE="${VPN_INTERFACE_PREFIX}/24"
VPN_GATEWAY_HOST_ROUTE="${VPN_GATEWAY}/32"

route_is_allowed() {
  local destination="$1"
  local entry
  local network
  local displayed_route
  local test_ip

  case "$destination" in
    "$VPN_INTERFACE_ROUTE"|\
    "$VPN_GATEWAY"|\
    "$VPN_GATEWAY_HOST_ROUTE")
      return 0
      ;;
  esac

  if [[ -n "${VPN_ALLOWED_HOST:-}" ]] &&
     [[ "$destination" == "$VPN_ALLOWED_HOST" ||
        "$destination" == "${VPN_ALLOWED_HOST}/32" ]]; then
    return 0
  fi

  for entry in "${VPN_ALLOWED_NETWORKS[@]}"; do
    IFS='|' read -r network displayed_route test_ip <<< "$entry"

    if [[ "$destination" == "$network" ||
          "$destination" == "$displayed_route" ]]; then
      return 0
    fi
  done

  return 1
}

ALL_ROUTES="$(
  netstat -rn -f inet |
    awk -v gateway="$VPN_GATEWAY" '$2 == gateway { print $1 }'
)"

ROUTE_DELETE_FAILED=0

while IFS= read -r destination; do
  [[ -n "$destination" ]] || continue

  if route_is_allowed "$destination"; then
    echo "Route saved: $destination"
  else
    echo "Deleting route: $destination"

    if ! sudo route -n delete -net "$destination" "$VPN_GATEWAY"; then
      echo "Failed to delete route: $destination"
      ROUTE_DELETE_FAILED=1
    fi
  fi
done <<< "$ALL_ROUTES"

if (( ROUTE_DELETE_FAILED )); then
  echo "One or more VPN routes could not be deleted"
  exit 1
fi

add_allowed_network_routes

echo "Configuring split DNS..."

sudo mkdir -p /etc/resolver
DNS_CONFIGURED=1

for domain in "${CORPORATE_DNS_DOMAINS[@]}"; do
  printf 'nameserver %s\n' "$VPN_CORPORATE_DNS" |
    sudo tee "/etc/resolver/$domain" >/dev/null
done

sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true

if [[ -n "${VPN_ALLOWED_HOST:-}" ]]; then
  PUBLIC_ROUTE_GATEWAY="$(
    route -n get "$VPN_ALLOWED_HOST" 2>/dev/null |
      awk '/gateway:/ { print $2; exit }' ||
      true
  )"

  if [[ "$PUBLIC_ROUTE_GATEWAY" != "$VPN_GATEWAY" ]]; then
    echo "Invalid route for $VPN_ALLOWED_HOST"
    echo "Expected gateway: $VPN_GATEWAY"
    echo "Actual gateway: ${PUBLIC_ROUTE_GATEWAY:-not found}"
    exit 1
  fi
fi

DNS_ROUTE_GATEWAY="$(
  route -n get "$VPN_CORPORATE_DNS" 2>/dev/null |
    awk '/gateway:/ { print $2; exit }' ||
    true
)"

if [[ "$DNS_ROUTE_GATEWAY" != "$VPN_GATEWAY" ]]; then
  echo "Invalid route for corporate DNS $VPN_CORPORATE_DNS"
  echo "Expected gateway: $VPN_GATEWAY"
  echo "Actual gateway: ${DNS_ROUTE_GATEWAY:-not found}"
  exit 1
fi

validate_allowed_network_routes

UNEXPECTED_ROUTES=""

while IFS= read -r destination; do
  [[ -n "$destination" ]] || continue

  if ! route_is_allowed "$destination"; then
    UNEXPECTED_ROUTES+="${destination}"$'\n'
  fi
done < <(
  netstat -rn -f inet |
    awk -v gateway="$VPN_GATEWAY" '$2 == gateway { print $1 }'
)

if [[ -n "$UNEXPECTED_ROUTES" ]]; then
  echo "Unexpected routes remain through VPN gateway:"
  printf '%s' "$UNEXPECTED_ROUTES"
  exit 1
fi

echo
echo "Routes processed"
echo "VPN session is active"
echo
echo "Press Ctrl+C to exit"

OPENCONNECT_EXIT_CODE=0
wait "$OPENCONNECT_PID" || OPENCONNECT_EXIT_CODE=$?
OPENCONNECT_PID=""

if (( OPENCONNECT_EXIT_CODE != 0 )); then
  if grep -Fq "'Idle Timeout'" "$LOG_FILE"; then
    echo "VPN session ended due to server idle timeout."
    exit 0
  fi

  echo "OpenConnect terminated with exit code: $OPENCONNECT_EXIT_CODE"
  exit "$OPENCONNECT_EXIT_CODE"
fi
