#!/usr/bin/env bash
# =============================================================================
# rthexplorer.sh — Send SMS and check status through a Huawei 4G/LTE router
#
# Talks to the router's local web API (the same one its web interface uses).
# No cloud service, no extra software on the router.
#
# Usage:
#   rthexplorer.sh send <number> [<number>...] <message>   Send an SMS to one or more numbers
#                                                (one login for all of them)
#   rthexplorer.sh inbox                                   Print unread received SMS, mark them read
#   rthexplorer.sh status                                  Check the router (no SMS sent)
#   rthexplorer.sh help                                    Show help
#
#   <number> may be a comma-separated list, or "default" (HUAWEI_SMS_TO).
#   <message> "-" reads the message from stdin.
#   Short form, kept for compatibility:  rthexplorer.sh <number> <message>
#
# Output:
#   Progress messages go to stderr.
#   One machine-readable result line goes to stdout (always the last line):
#     STATUS=OK;SMS=sent;SENT=2/2
#     STATUS=OK;SIGNAL=4/5;OPERATOR=Orange F
#     STATUS=OK;COUNT=1          (inbox: preceded by one JSON line per message)
#     STATUS=ERROR;DETAIL=<human readable reason>[;SENT=1/2][;LIMITED=1]
#
# Exit codes:
#   0  success
#   1  failure (router unreachable, login refused, SIM problem, SMS refused…)
#   2  wrong usage
#   3  rate limit reached: some or all SMS were not sent (see HUAWEI_SMS_LIMIT)
#
# Configuration (environment variables override the config file):
#   HUAWEI_ROUTER_URL   default: https://192.168.8.1
#   HUAWEI_USERNAME     default: admin
#   HUAWEI_PASSWORD     required (unless the device has no login)
#   HUAWEI_SMS_TO       default recipients for "send default", comma-separated
#   HUAWEI_SMS_LIMIT    max SMS per window, 0 = no limit (default: 0)
#   HUAWEI_SMS_WINDOW   rate limit window in seconds (default: 3600)
#   HUAWEI_STATE_FILE   where sent SMS are counted, default: .rthexplorer_sent next to this script
#   HUAWEI_CONFIG       config file, default: rthexplorer.conf next to this script
#
# Requirements: bash, curl, python3, awk, mktemp
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

# Bash 5.2+ would turn "&" in a ${var//pattern/replacement} into the matched text: keep it literal.
shopt -u patsub_replacement 2>/dev/null || true

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
  $(basename "$0") send <number> [<number>...] <message>   Send an SMS (one login for all numbers)
  $(basename "$0") inbox                                   Print unread SMS as JSON lines, mark them read
  $(basename "$0") status                                  Check the router (no SMS sent)
  $(basename "$0") help                                    Show this help

  <number>  +33612345678, a comma-separated list, or "default" (HUAWEI_SMS_TO)
  <message> text, or "-" to read it from stdin

Configuration: $CONFIG_FILE
  or environment variables HUAWEI_ROUTER_URL, HUAWEI_USERNAME, HUAWEI_PASSWORD,
  HUAWEI_SMS_TO, HUAWEI_SMS_LIMIT, HUAWEI_SMS_WINDOW, HUAWEI_STATE_FILE
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

SMS_TO="${HUAWEI_SMS_TO:-$(read_config_value HUAWEI_SMS_TO)}"
SMS_LIMIT="${HUAWEI_SMS_LIMIT:-$(read_config_value HUAWEI_SMS_LIMIT)}"
SMS_WINDOW="${HUAWEI_SMS_WINDOW:-$(read_config_value HUAWEI_SMS_WINDOW)}"
STATE_FILE="${HUAWEI_STATE_FILE:-$(read_config_value HUAWEI_STATE_FILE)}"

[[ "$SMS_LIMIT" =~ ^[0-9]+$ ]] || SMS_LIMIT=0
[[ "$SMS_WINDOW" =~ ^[0-9]+$ && "$SMS_WINDOW" -gt 0 ]] || SMS_WINDOW=3600
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/.rthexplorer_sent}"

# -----------------------------------------------------------------------------
# Small tools (python3 is used instead of "grep -P" or openssl, so the script
# also runs on minimal systems such as Alpine or BusyBox-based images)
# -----------------------------------------------------------------------------

# Huawei login hash: base64( hex( sha256(value) ) )
sha256_hex_base64() {
    printf '%s' "$1" | python3 -c '
import sys, hashlib, base64
digest = hashlib.sha256(sys.stdin.buffer.read()).hexdigest()
sys.stdout.write(base64.b64encode(digest.encode("ascii")).decode("ascii"))
'
}

xml_escape() {
    printf '%s' "$1" | python3 -c '
import sys
from xml.sax.saxutils import escape
sys.stdout.write(escape(sys.stdin.read()))
'
}

# Print the text of an XML tag read from stdin (first occurrence)
xml_tag() {
    python3 -c '
import re, sys
match = re.search(r"<%s>([^<]*)</%s>" % (sys.argv[1], sys.argv[1]), sys.stdin.read())
sys.stdout.write(match.group(1).strip() if match else "")
' "$1"
}

# Anti-CSRF token published in a web page (<meta name="csrf_token" content="...">)
page_csrf() {
    python3 -c '
import re, sys
tokens = re.findall(r"<meta name=\"csrf_token\" content=\"([^\"]+)\"", sys.stdin.read())
sys.stdout.write(tokens[-1] if tokens else "")
' | tr -cd '[:alnum:]'
}

base64_text() {
    printf '%s' "$1" | python3 -c '
import sys, base64
sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))
'
}

random_hex32() {
    python3 -c 'import secrets; print(secrets.token_hex(32), end="")'
}

# SCRAM login proof used by recent Huawei web interfaces.
# Arguments: salt (hex), iterations, client nonce, server nonce.
# Prints "<client_proof> <expected_server_signature>". The password is read from
# stdin, never passed on the command line.
# Note: Huawei swaps the HMAC key and message compared to RFC 5802, exactly as
# the router's own JavaScript does.
scram_proof() {
    printf '%s' "$PASSWORD" | python3 -c '
import sys, hashlib, hmac
salt, iterations = bytes.fromhex(sys.argv[1]), int(sys.argv[2])
first, server = sys.argv[3], sys.argv[4]
auth = ("%s,%s,%s" % (first, server, server)).encode()
salted = hashlib.pbkdf2_hmac("sha256", sys.stdin.buffer.read(), salt, iterations, 32)
client_key = hmac.new(b"Client Key", salted, hashlib.sha256).digest()
stored_key = hashlib.sha256(client_key).digest()
signature = hmac.new(auth, stored_key, hashlib.sha256).digest()
proof = bytes(a ^ b for a, b in zip(client_key, signature)).hex()
server_key = hmac.new(b"Server Key", salted, hashlib.sha256).digest()
print(proof, hmac.new(auth, server_key, hashlib.sha256).hexdigest())
' "$1" "$2" "$3" "$4"
}

# Number of characters (not bytes) of a text
char_count() {
    python3 -c 'import sys; print(len(sys.argv[1]))' "$1"
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

# --- Rate limit ---------------------------------------------------------------
# Every SMS accepted by the router is recorded (one timestamp per line) in
# $STATE_FILE. Only the last $SMS_WINDOW seconds are kept.

# Print how many more SMS may be sent now ("unlimited" if no limit)
rate_remaining() {
    if [[ "$SMS_LIMIT" -eq 0 ]]; then
        echo unlimited
        return
    fi
    local now used
    now="$(date +%s)"
    used=0
    if [[ -r "$STATE_FILE" ]]; then
        used="$(awk -v min="$(( now - SMS_WINDOW ))" '$1 >= min' "$STATE_FILE" | wc -l | tr -d ' ')"
    fi
    echo $(( SMS_LIMIT > used ? SMS_LIMIT - used : 0 ))
}

# Record one sent SMS and forget the ones older than the window
rate_record() {
    [[ "$SMS_LIMIT" -eq 0 ]] && return 0
    local now tmp
    now="$(date +%s)"
    tmp="$(mktemp)"
    {
        [[ -r "$STATE_FILE" ]] && awk -v min="$(( now - SMS_WINDOW ))" '$1 >= min' "$STATE_FILE"
        echo "$now"
    } > "$tmp"
    cat "$tmp" > "$STATE_FILE" 2>/dev/null || log "cannot write $STATE_FILE (rate limit not recorded)"
    rm -f -- "$tmp"
}

# --- Send ---------------------------------------------------------------------

# Send one SMS in the current session. Prints the router error code on failure.
send_one() {
    local phone="$1" message="$2" token length date body answer
    token="$(fresh_token)" || token=""
    if [[ -z "$token" ]]; then
        echo "no token"
        return 1
    fi
    length="$(char_count "$message")"
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
    answer="$(api_post "/api/sms/send-sms" "$token" "$body")" || { echo "no answer"; return 1; }
    printf '%s' "$answer" | grep -q "<response>OK</response>" && return 0
    echo "code $(printf '%s' "$answer" | error_code)"
    return 1
}

# Usage: cmd_send <number> [<number>...] <message>
cmd_send() {
    local message="${*: -1}"
    local -a recipients=() parts=()
    local arg number

    # Recipients: each argument but the last; commas and "default" are expanded
    for arg in "${@:1:$#-1}"; do
        [[ "$arg" == "default" ]] && arg="$SMS_TO"
        IFS=',' read -r -a parts <<< "$arg"
        for number in "${parts[@]}"; do
            number="${number//[[:space:]]/}"
            [[ -n "$number" ]] || continue
            [[ " ${recipients[*]} " == *" $number "* ]] || recipients+=("$number")
        done
    done
    [[ ${#recipients[@]} -gt 0 ]] || fail "no recipient (give a number, or set HUAWEI_SMS_TO for \"default\")"

    if [[ "$message" == "-" ]]; then
        message="$(cat)"
    fi
    [[ -n "$message" ]] || fail "empty message"

    local total=${#recipients[@]} remaining
    remaining="$(rate_remaining)"
    if [[ "$remaining" == "0" ]]; then
        echo "[ERROR] rate limit reached ($SMS_LIMIT SMS per $SMS_WINDOW s): nothing sent" >&2
        echo "STATUS=ERROR;DETAIL=rate limit reached ($SMS_LIMIT SMS per $SMS_WINDOW s);SENT=0/$total;LIMITED=1"
        exit 3
    fi

    login

    local sent=0 limited=0 errors="" result
    for number in "${recipients[@]}"; do
        if [[ "$remaining" != "unlimited" && "$sent" -ge "$remaining" ]]; then
            limited=1
            log "Rate limit reached: $number skipped"
            continue
        fi
        log "Sending SMS to $number..."
        if result="$(send_one "$number" "$message")"; then
            sent=$(( sent + 1 ))
            rate_record
            ok "SMS to $number accepted by the router"
        else
            errors+="${errors:+, }$number ($result)"
            echo "[ERROR] SMS to $number refused ($result)" >&2
        fi
    done

    if [[ -n "$errors" ]]; then
        echo "STATUS=ERROR;DETAIL=SMS refused for $errors;SENT=$sent/$total$([[ $limited == 1 ]] && echo ';LIMITED=1')"
        exit 1
    fi
    if [[ "$limited" == "1" ]]; then
        echo "STATUS=ERROR;DETAIL=rate limit reached ($SMS_LIMIT SMS per $SMS_WINDOW s);SENT=$sent/$total;LIMITED=1"
        exit 3
    fi
    echo "STATUS=OK;SMS=sent;SENT=$sent/$total"
    exit 0
}

# --- Inbox --------------------------------------------------------------------

json_escape() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//$'\t'/ }"
    printf '%s' "$text"
}

xml_unescape() {
    local text="$1"
    text="${text//&lt;/<}"
    text="${text//&gt;/>}"
    text="${text//&quot;/\"}"
    text="${text//&apos;/\'}"
    text="${text//&#39;/\'}"
    text="${text//&amp;/&}"
    printf '%s' "$text"
}

# Print unread received SMS (one JSON object per line), then mark them read.
cmd_inbox() {
    login

    local token body answer
    token="$(fresh_token)" || token=""
    [[ -n "$token" ]] || fail "cannot get a token to read the SMS"
    body='<?xml version="1.0" encoding="UTF-8"?>
<request>
    <PageIndex>1</PageIndex>
    <ReadCount>50</ReadCount>
    <BoxType>1</BoxType>
    <SortType>0</SortType>
    <Ascending>1</Ascending>
    <UnreadPreferred>1</UnreadPreferred>
</request>'
    answer="$(api_post "/api/sms/sms-list" "$token" "$body")" || fail "no answer from the router while reading SMS"
    printf '%s' "$answer" | grep -q "<error>" && fail "cannot read the SMS (code $(printf '%s' "$answer" | error_code))"

    # One message per line (pure bash, no XML tool needed)
    answer="${answer//$'\r'/ }"
    answer="${answer//$'\n'/ }"
    answer="${answer//<\/Message>/$'\n'}"

    local count=0 line index phone date text
    while IFS= read -r line; do
        [[ "$line" =~ \<Smstat\>0\</Smstat\> ]] || continue          # 0 = unread
        [[ "$line" =~ \<Index\>([^<]*)\</Index\> ]] && index="${BASH_REMATCH[1]}" || continue
        [[ "$line" =~ \<Phone\>([^<]*)\</Phone\> ]] && phone="${BASH_REMATCH[1]}" || phone=""
        [[ "$line" =~ \<Date\>([^<]*)\</Date\> ]] && date="${BASH_REMATCH[1]}" || date=""
        [[ "$line" =~ \<Content\>([^<]*)\</Content\> ]] && text="${BASH_REMATCH[1]}" || text=""
        text="$(xml_unescape "$text")"
        printf '{"index":"%s","from":"%s","date":"%s","text":"%s"}\n' \
            "$(json_escape "$index")" "$(json_escape "$(xml_unescape "$phone")")" \
            "$(json_escape "$date")" "$(json_escape "$text")"
        count=$(( count + 1 ))

        token="$(fresh_token)" || token=""
        [[ -n "$token" ]] && api_post "/api/sms/set-read" "$token" \
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Index>$index</Index></request>" >/dev/null
    done <<< "$answer"

    ok "$count unread SMS"
    echo "STATUS=OK;COUNT=$count"
    exit 0
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

for tool in curl python3 awk mktemp; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

case "${1:-}" in
    status)
        cmd_status
        ;;
    inbox)
        cmd_inbox
        ;;
    send)
        shift
        if [[ $# -lt 2 ]]; then
            usage
            exit 2
        fi
        cmd_send "$@"
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
        # Short form: rthexplorer.sh <number> <message>
        if [[ $# -lt 2 ]]; then
            usage
            exit 2
        fi
        cmd_send "$@"
        ;;
esac
