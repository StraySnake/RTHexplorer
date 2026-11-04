#!/usr/bin/env bash
# =============================================================================
# rthexplorer_bash.sh — Send SMS and check status through a Huawei 4G/LTE router
#
# Pure shell variant of rthexplorer.sh: same commands, same configuration,
# same output, but NO python3 (uses openssl, base64 and sed instead).
#
# Talks to the router's local web API (the same one its web interface uses).
# No cloud service, no extra software on the router.
#
# Usage:
#   rthexplorer_bash.sh send <phone_number> <message>   Send an SMS
#   rthexplorer_bash.sh status                          Check the router (no SMS sent)
#   rthexplorer_bash.sh help                            Show help
#
#   Short form, kept for compatibility:
#   rthexplorer_bash.sh <phone_number> <message>
#
# Output:
#   Progress messages go to stderr.
#   One machine-readable result line goes to stdout:
#     STATUS=OK;SMS=sent
#     STATUS=OK;SIGNAL=4/5;OPERATOR=Orange F
#     STATUS=ERROR;DETAIL=<human readable reason>
#
# Exit codes:
#   0  success
#   1  failure (router unreachable, login refused, SIM problem, SMS refused…)
#   2  wrong usage
#
# Configuration (environment variables override the config file):
#   HUAWEI_ROUTER_URL   default: https://192.168.8.1
#   HUAWEI_USERNAME     default: admin
#   HUAWEI_PASSWORD     required
#   HUAWEI_CONFIG       config file, default: rthexplorer.conf next to this script
#
# Requirements: bash, curl, openssl, base64, sed, awk, mktemp, tr
#
# Copyright (C) 2026 StraySnake — https://github.com/StraySnake/RTHexplorer
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details: <https://www.gnu.org/licenses/>.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HUAWEI_CONFIG:-$SCRIPT_DIR/rthexplorer.conf}"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

log() {
    echo "[INFO] $*" >&2
}

ok() {
    echo "[OK] $*" >&2
}

fail() {
    echo "[ERROR] $1" >&2
    echo "STATUS=ERROR;DETAIL=$1"
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage:
  $(basename "$0") send <phone_number> <message>   Send an SMS
  $(basename "$0") status                          Check the router (no SMS sent)
  $(basename "$0") help                            Show this help

Configuration: $CONFIG_FILE
  or environment variables HUAWEI_ROUTER_URL, HUAWEI_USERNAME, HUAWEI_PASSWORD
EOF
}

# -----------------------------------------------------------------------------
# Configuration
# The config file is read as plain KEY=VALUE lines (it is never executed).
# -----------------------------------------------------------------------------

read_config_value() {
    local key="$1"
    [[ -r "$CONFIG_FILE" ]] || return 0
    awk -v key="$key" -v q="'" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (index(line, key "=") == 1) {
                value = substr(line, length(key) + 2)
                sub(/[[:space:]]+$/, "", value)
                first = substr(value, 1, 1)
                last = substr(value, length(value), 1)
                if (length(value) >= 2 && first == last && (first == "\"" || first == q)) {
                    value = substr(value, 2, length(value) - 2)
                }
                result = value
            }
        }
        END { printf "%s", result }
    ' "$CONFIG_FILE"
}

ROUTER_URL="${HUAWEI_ROUTER_URL:-$(read_config_value HUAWEI_ROUTER_URL)}"
USERNAME="${HUAWEI_USERNAME:-$(read_config_value HUAWEI_USERNAME)}"
PASSWORD="${HUAWEI_PASSWORD:-$(read_config_value HUAWEI_PASSWORD)}"

ROUTER_URL="${ROUTER_URL:-https://192.168.8.1}"
ROUTER_URL="${ROUTER_URL%/}"
USERNAME="${USERNAME:-admin}"

# -----------------------------------------------------------------------------
# Small tools (pure shell: openssl + base64 + sed, no python3, no "grep -P")
# -----------------------------------------------------------------------------

# Huawei login hash: base64( hex( sha256(value) ) )
sha256_hex_base64() {
    printf '%s' "$1" | openssl dgst -sha256 -hex | awk '{ print $NF }' | tr -d '\n' | base64 | tr -d '\n'
}

# Bash 5.2+ would turn "&" in a replacement into the matched text: keep it literal.
shopt -u patsub_replacement 2>/dev/null || true

xml_escape() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    printf '%s' "$text"
}

# Print the text of an XML tag read from stdin
xml_tag() {
    tr -d '\r\n' | sed -n "s:.*<$1>[[:space:]]*\([^<]*[^<[:space:]]\)[[:space:]]*</$1>.*:\1:p"
}

# Print the router's error code from an API answer, if any
error_code() {
    xml_tag code
}

# -----------------------------------------------------------------------------
# HTTP session with the router
# -----------------------------------------------------------------------------

COOKIE_JAR=""
LOGGED_IN=0

CURL_OPTIONS=(
    --insecure              # routers use a self-signed HTTPS certificate
    --silent --show-error
    --connect-timeout 5
    --max-time 15
)

api_get() {
    curl "${CURL_OPTIONS[@]}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$ROUTER_URL$1" 2>/dev/null
}

api_post() {
    local path="$1" token="$2" body="$3"
    curl "${CURL_OPTIONS[@]}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -H "__RequestVerificationToken: $token" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -X POST "$ROUTER_URL$path" \
        --data "$body" 2>/dev/null
}

# A fresh anti-CSRF token is required before each POST request
fresh_token() {
    api_get "/api/webserver/token" | xml_tag token
}

logout() {
    if [[ "$LOGGED_IN" == "1" ]]; then
        local token
        token="$(fresh_token)" || token=""
        if [[ -n "$token" ]]; then
            api_post "/api/user/logout" "$token" \
                '<?xml version="1.0" encoding="UTF-8"?><request><Logout>1</Logout></request>' \
                >/dev/null || true
        fi
        LOGGED_IN=0
    fi
}

cleanup() {
    logout
    [[ -n "$COOKIE_JAR" ]] && rm -f -- "$COOKIE_JAR"
}

login() {
    [[ -n "$PASSWORD" ]] || fail "no password configured (set HUAWEI_PASSWORD or edit $CONFIG_FILE)"

    COOKIE_JAR="$(mktemp)"
    trap cleanup EXIT

    log "Connecting to $ROUTER_URL..."

    local page csrf
    page="$(curl "${CURL_OPTIONS[@]}" -c "$COOKIE_JAR" "$ROUTER_URL/html/home.html" 2>/dev/null)" \
        || fail "router unreachable at $ROUTER_URL (powered off, cable, network?)"

    awk '$6 == "SessionID" { found = 1 } END { exit !found }' "$COOKIE_JAR" \
        || fail "the router did not open a session"

    # The anti-CSRF token is published in the home page (<meta name="csrf_token">).
    # Some firmwares only publish it through /api/webserver/SesTokInfo.
    csrf="$(printf '%s' "$page" | tr -d '\r\n' \
        | sed -n 's/.*<meta name="csrf_token" content="\([^"]*\)".*/\1/p' | tr -cd '[:alnum:]')"
    if [[ -z "$csrf" ]]; then
        csrf="$(api_get "/api/webserver/SesTokInfo" | xml_tag TokInfo)"
    fi
    [[ -n "$csrf" ]] || fail "anti-CSRF token not found"
    ok "Session opened"

    local password_hash login_hash body answer
    password_hash="$(sha256_hex_base64 "$PASSWORD")"
    login_hash="$(sha256_hex_base64 "${USERNAME}${password_hash}${csrf}")"
    body="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<request>
    <Username>$(xml_escape "$USERNAME")</Username>
    <Password>$login_hash</Password>
    <password_type>4</password_type>
</request>"

    answer="$(api_post "/api/user/login" "$csrf" "$body")" \
        || fail "no answer from the router during login"

    if ! printf '%s' "$answer" | grep -q "<response>OK</response>"; then
        local code
        code="$(printf '%s' "$answer" | error_code)"
        case "$code" in
            108001|108002|108006) fail "login refused: wrong username or password (code $code)" ;;
            108003|108005)        fail "login refused: another session is already open (code $code)" ;;
            108007)               fail "login refused: too many attempts, try again later (code $code)" ;;
            *)             fail "login refused (code ${code:-unknown})" ;;
        esac
    fi
    LOGGED_IN=1
    ok "Logged in as $USERNAME"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

# Read-only check: login, SIM, mobile network, signal. No SMS is sent.
cmd_status() {
    login

    local status plmn sim signal operator
    status="$(api_get "/api/monitoring/status")" || fail "cannot read the router status"
    plmn="$(api_get "/api/net/current-plmn")" || plmn=""

    sim="$(printf '%s' "$status" | xml_tag SimStatus)"
    signal="$(printf '%s' "$status" | xml_tag SignalIcon)"
    operator="$(printf '%s' "$plmn" | xml_tag ShortName)"
    [[ -n "$operator" ]] || operator="$(printf '%s' "$plmn" | xml_tag FullName)"

    [[ "$sim" == "1" ]] || fail "SIM card missing, locked or waiting for PIN (SimStatus=${sim:-?})"
    [[ -n "$signal" && "$signal" != "0" ]] || fail "no mobile network (signal 0/5)"

    ok "SIM ready, signal ${signal}/5, operator ${operator:-unknown}"
    echo "STATUS=OK;SIGNAL=${signal}/5;OPERATOR=${operator:-unknown}"
    exit 0
}

cmd_send() {
    local phone="$1" message="$2"

    login

    log "Sending SMS to $phone..."
    local token
    token="$(fresh_token)" || token=""
    [[ -n "$token" ]] || fail "cannot get a token to send the SMS"

    local length date body answer
    length="${#message}"     # number of characters (with a UTF-8 locale)
    date="$(date "+%Y-%m-%d %H:%M:%S")"
    body="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<request>
    <Index>-1</Index>
    <Phones>
        <Phone>$(xml_escape "$phone")</Phone>
    </Phones>
    <Sca></Sca>
    <Content>$(xml_escape "$message")</Content>
    <Length>$length</Length>
    <Reserved>1</Reserved>
    <Date>$date</Date>
</request>"

    answer="$(api_post "/api/sms/send-sms" "$token" "$body")" \
        || fail "no answer from the router while sending"

    if printf '%s' "$answer" | grep -q "<response>OK</response>"; then
        ok "SMS accepted by the router"
        echo "STATUS=OK;SMS=sent"
        exit 0
    fi
    fail "SMS refused by the router (code $(printf '%s' "$answer" | error_code))"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

for tool in curl openssl base64 sed awk mktemp tr; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

case "${1:-}" in
    status)
        cmd_status
        ;;
    send)
        if [[ -z "${2:-}" || -z "${3:-}" ]]; then
            usage
            exit 2
        fi
        cmd_send "$2" "$3"
        ;;
    help|-h|--help)
        usage
        exit 0
        ;;
    "")
        usage
        exit 2
        ;;
    *)
        # Short form: rthexplorer.sh <phone_number> <message>
        if [[ -z "${2:-}" ]]; then
            usage
            exit 2
        fi
        cmd_send "$1" "$2"
        ;;
esac
