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
# Requirements: bash, curl, openssl (3.0+ for SCRAM routers), base64, sed, awk, mktemp, tr, od
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

# Anti-CSRF token published in a web page (<meta name="csrf_token" content="...">)
page_csrf() {
    tr -d '\r\n' | sed -n 's/.*<meta name="csrf_token" content="\([^"]*\)".*/\1/p' | tr -cd '[:alnum:]'
}

base64_text() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

random_hex32() {
    openssl rand -hex 32
}

# Text -> hexadecimal
hex_of() {
    printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

# Hexadecimal -> raw bytes on stdout
hex_to_bin() {
    local hex="$1" escaped="" i
    for (( i = 0; i < ${#hex}; i += 2 )); do
        escaped+="\\x${hex:i:2}"
    done
    printf '%b' "$escaped"
}

sha256_of_hex() {
    hex_to_bin "$1" | openssl dgst -sha256 | awk '{ print $NF }'
}

# HMAC-SHA256 with a text key and a hexadecimal message
hmac_sha256() {
    hex_to_bin "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(hex_of "$1")" | awk '{ print $NF }'
}

# SCRAM login proof used by recent Huawei web interfaces (needs OpenSSL 3.0+).
# Arguments: salt (hex), iterations, client nonce, server nonce.
# Prints "<client_proof> <expected_server_signature>".
# Note: Huawei swaps the HMAC key and message compared to RFC 5802, exactly as
# the router's own JavaScript does.
scram_proof() {
    local salt="$1" iterations="$2" first="$3" server="$4"
    local auth="${first},${server},${server}"
    local salted client_key stored_key signature server_key proof="" i

    salted="$(openssl kdf -keylen 32 -kdfopt digest:SHA256 \
        -kdfopt "hexpass:$(hex_of "$PASSWORD")" -kdfopt "hexsalt:$salt" \
        -kdfopt "iter:$iterations" PBKDF2 2>/dev/null | tr -d ':\n' | tr 'A-F' 'a-f')"
    [[ ${#salted} -eq 64 ]] || return 1

    client_key="$(hmac_sha256 "Client Key" "$salted")"
    stored_key="$(sha256_of_hex "$client_key")"
    signature="$(hmac_sha256 "$auth" "$stored_key")"
    for (( i = 0; i < 64; i += 2 )); do
        proof+="$(printf '%02x' $(( 0x${client_key:i:2} ^ 0x${signature:i:2} )))"
    done
    server_key="$(hmac_sha256 "Server Key" "$salted")"
    echo "$proof $(hmac_sha256 "$auth" "$server_key")"
}

# Print the router's error code from an API answer, if any
error_code() {
    xml_tag code
}

# -----------------------------------------------------------------------------
# HTTP session with the router
# -----------------------------------------------------------------------------

COOKIE_JAR=""
HEADERS=""
CSRF=""
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

# POST an XML request; the answer headers are kept in $HEADERS
api_post() {
    local path="$1" token="$2" body="$3"
    curl "${CURL_OPTIONS[@]}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -D "$HEADERS" \
        -H "__RequestVerificationToken: $token" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -X POST "$ROUTER_URL$path" \
        --data "$body" 2>/dev/null
}

# A fresh anti-CSRF token is required before each POST request
fresh_token() {
    api_get "/api/webserver/token" | xml_tag token
}

# New anti-CSRF token sent back by the router with the last POST answer, if any
header_token() {
    awk -F': *' '
        { name = tolower($1) }
        name == "__requestverificationtoken" || name == "__requestverificationtokenone" { print $2; exit }
    ' "$HEADERS" 2>/dev/null | tr -d '\r' | cut -d'#' -f1
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
    [[ -n "$HEADERS" ]] && rm -f -- "$HEADERS"
}

# Open a web session: session cookie + anti-CSRF token in $CSRF
open_session() {
    local page
    page="$(curl "${CURL_OPTIONS[@]}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$ROUTER_URL/html/home.html" 2>/dev/null)" \
        || fail "router unreachable at $ROUTER_URL (powered off, cable, network?)"

    awk '$6 == "SessionID" { found = 1 } END { exit !found }' "$COOKIE_JAR" \
        || fail "the router did not open a session"

    # Most firmwares publish the token in the home page; some only through SesTokInfo.
    CSRF="$(printf '%s' "$page" | page_csrf)"
    if [[ -z "$CSRF" ]]; then
        CSRF="$(api_get "/api/webserver/SesTokInfo" | xml_tag TokInfo)"
    fi
    [[ -n "$CSRF" ]] || fail "anti-CSRF token not found"
}

login_refused() {
    local code
    code="$(printf '%s' "$1" | error_code)"
    case "$code" in
        108001|108002|108006) fail "login refused: wrong username or password (code $code)" ;;
        108003|108005)        fail "login refused: another session is already open (code $code)" ;;
        108007)               fail "login refused: too many attempts, try again later (code $code)" ;;
        115002)               fail "login refused: the router asks to change the default password first (code $code)" ;;
        *)                    fail "login refused (code ${code:-unknown})" ;;
    esac
}

# Classic login (POST /api/user/login).
#   password_type 4    : base64(sha256hex(username + base64(sha256hex(password)) + token))
#   password_type 0, 3 : base64(password)   (older firmwares)
classic_login() {
    local type="$1" password body answer
    if [[ "$type" == "4" ]]; then
        password="$(sha256_hex_base64 "${USERNAME}$(sha256_hex_base64 "$PASSWORD")${CSRF}")"
    else
        password="$(base64_text "$PASSWORD")"
    fi
    body="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<request>
    <Username>$(xml_escape "$USERNAME")</Username>
    <Password>$password</Password>
    <password_type>$type</password_type>
</request>"

    answer="$(api_post "/api/user/login" "$CSRF" "$body")" \
        || fail "no answer from the router during login"
    printf '%s' "$answer" | grep -q "<response>OK</response>" || login_refused "$answer"
}

# SCRAM login (challenge_login + authentication_login) used by recent web
# interfaces. Returns 1 if the router does not offer it.
scram_login() {
    local first answer salt iterations server token proof expected received
    first="$(random_hex32)"
    answer="$(api_post "/api/user/challenge_login" "$CSRF" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<request>
    <username>$(xml_escape "$USERNAME")</username>
    <firstnonce>$first</firstnonce>
    <mode>1</mode>
</request>")" || return 1

    salt="$(printf '%s' "$answer" | xml_tag salt)"
    iterations="$(printf '%s' "$answer" | xml_tag iterations)"
    server="$(printf '%s' "$answer" | xml_tag servernonce)"
    [[ -n "$salt" && -n "$iterations" && -n "$server" ]] || return 1

    read -r proof expected <<< "$(scram_proof "$salt" "$iterations" "$first" "$server")"
    [[ -n "$proof" ]] || fail "could not compute the SCRAM login (OpenSSL 3.0+ or python3 needed)"

    token="$(header_token)"
    [[ -n "$token" ]] || token="$(fresh_token)"
    answer="$(api_post "/api/user/authentication_login" "$token" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<request>
    <clientproof>$proof</clientproof>
    <finalnonce>$server</finalnonce>
</request>")" || fail "no answer from the router during login"

    received="$(printf '%s' "$answer" | xml_tag serversignature)"
    [[ -n "$received" ]] || login_refused "$answer"
    [[ "$received" == "$expected" ]] || fail "login aborted: the router's identity could not be verified"
}

login() {
    COOKIE_JAR="$(mktemp)"
    HEADERS="$(mktemp)"
    trap cleanup EXIT

    log "Connecting to $ROUTER_URL..."
    open_session
    ok "Session opened"

    # Which login does this firmware expect?
    local state logged type
    state="$(api_get "/api/user/state-login")"
    logged="$(printf '%s' "$state" | xml_tag State)"
    type="$(printf '%s' "$state" | xml_tag password_type)"

    if [[ "$logged" == "0" ]]; then
        ok "No login needed (device without password, or session already open)"
        return 0
    fi

    [[ -n "$PASSWORD" ]] || fail "no password configured (set HUAWEI_PASSWORD or edit $CONFIG_FILE)"

    if [[ "$type" == "4" || -z "$type" ]]; then
        if scram_login; then
            LOGGED_IN=1
            ok "Logged in as $USERNAME (SCRAM)"
            return 0
        fi
        # SCRAM not offered: start again with a clean session for the classic login
        open_session
        type=4
    fi

    classic_login "$type"
    LOGGED_IN=1
    ok "Logged in as $USERNAME (password type $type)"
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

for tool in curl openssl base64 sed awk mktemp tr od; do
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
