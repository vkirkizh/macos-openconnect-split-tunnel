#!/bin/bash
# shellcheck disable=SC2034

# Copy this file to config.sh and replace all example values.

# The example addresses below use private or documentation-only ranges.
# Do not commit your real corporate values.

CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CHROME_PROFILE_DIR="${HOME}/.local/share/openconnect-sso-chrome"

CDP_PORT="9222"

VPN_HOST="vpn.example.com"
COOKIE_NAME="webvpn"

# Optional standalone host route expected to be pushed by the VPN server.
# The script preserves and validates this route but does not create it.
# Leave empty if no standalone host is required.
VPN_ALLOWED_HOST=""
# VPN_ALLOWED_HOST="203.0.113.10"

# Corporate DNS used only for the domains listed below.
VPN_CORPORATE_DNS="10.40.0.1"

# Networks that must remain reachable through the VPN.
#
# Entry format, without spaces around separators:
# canonical-CIDR|netstat-route|test-IP
#
# macOS may abbreviate network routes in netstat output.
# For example, 10.40.0.0/16 may appear as 10.40/16.
#
# The test IP must belong to the corresponding network.
# It is used to verify that the final route points to the VPN gateway.
VPN_ALLOWED_NETWORKS=(
  "10.20.30.0/24|10.20.30/24|10.20.30.1"
  "10.40.0.0/16|10.40/16|10.40.0.10"
)

# Regex for detecting the VPN gateway in the routing table.
VPN_GATEWAY_REGEX='^10\.50\.[0-9]+\.[0-9]+$'

CORPORATE_DNS_DOMAINS=(
  "corp.example.com"
  "internal.example.net"
)

# Optional. Increase this if vpnc-script needs more time to finish adding routes before the cleanup pass starts.
VPN_ROUTE_SETUP_DELAY_SECONDS="3"
