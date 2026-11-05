#!/usr/bin/env bash
# =============================================================================
# Automated tests for rthexplorer.sh and rthexplorer_bash.sh
#
# Both scripts are run against a simulated Huawei router (tests/mock_router.py),
# one per firmware behaviour. No real router, SIM card or SMS is needed.
#
# Usage:  tests/run_tests.sh            test both scripts
#         tests/run_tests.sh rthexplorer_bash.sh
# Requirements: bash, curl, python3, openssl
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
PASSWORD='p@ss w0rd"x'
if [[ $# -gt 0 ]]; then
    SCRIPTS=("$@")
else
    SCRIPTS=(rthexplorer.sh rthexplorer_bash.sh)
fi

PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    rm -rf -- "$WORK"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1 \
    || { echo "openssl is required"; exit 1; }

PASSED=0
FAILED=0
NEXT_PORT=18400

# Start a simulated router; sets ROUTER (its URL) and LOGS (its log folder)
start_router() {
    local mode="$1" port=$(( NEXT_PORT++ ))
    LOGS="$WORK/router-$port"
    mkdir -p "$LOGS"
    python3 -u "$HERE/mock_router.py" "$mode" "$port" "$WORK/cert.pem" "$WORK/key.pem" "$LOGS" \
        2> "$LOGS/stderr.log" &
    PIDS+=($!)
    local ready=0
    for _ in $(seq 1 100); do
        if curl -ks --noproxy '*' "https://127.0.0.1:$port/html/home.html" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if (( ready == 0 )); then
        echo "  !!    simulated router ($mode) not reachable on port $port"
        curl -kvs --noproxy '*' "https://127.0.0.1:$port/html/home.html" 2>&1 | sed 's/^/        curl: /' | head -20
        sed 's/^/        mock: /' "$LOGS/stderr.log"
    fi
    ROUTER="https://127.0.0.1:$port"
}

# Run the script under test with a clean configuration
run() {
    env HUAWEI_CONFIG=/nonexistent HUAWEI_PASSWORD="$PASSWORD" HUAWEI_ROUTER_URL="$ROUTER" \
        HUAWEI_STATE_FILE="$WORK/sent-state" HUAWEI_SMS_TO_FILE="$WORK/no-recipients" \
        "$@" 2>/dev/null
}

# check <description> <expected exit code> <expected text> <actual output> <actual exit code>
check() {
    local description="$1" expected_code="$2" expected="$3" output="$4" code="$5"
    if [[ "$code" == "$expected_code" && "$output" == *"$expected"* ]]; then
        PASSED=$(( PASSED + 1 ))
        echo "  ok    $description"
    else
        FAILED=$(( FAILED + 1 ))
        echo "  FAIL  $description"
        echo "        expected exit $expected_code and: $expected"
        echo "        got      exit $code and: $output"
    fi
}

for script_name in "${SCRIPTS[@]}"; do
    S="$ROOT/$script_name"
    echo "=== $script_name"

    # --- syntax and usage ---------------------------------------------------
    bash -n "$S"; check "bash syntax" 0 "" "" "$?"
    out="$(bash "$S" 2>&1)"; check "no argument shows usage" 2 "Usage:" "$out" "$?"
    out="$(bash "$S" help 2>&1)"; check "help" 0 "Usage:" "$out" "$?"
    out="$(bash "$S" send +33611111111 2>&1)"; check "send without message" 2 "Usage:" "$out" "$?"

    # --- login methods --------------------------------------------------------
    for mode in sha256 scram b64 type3 nologin nostate sestok; do
        start_router "$mode"
        out="$(run bash "$S" status)"
        check "status, login $mode" 0 "STATUS=OK;SIGNAL=4/5;OPERATOR=Test Mobile;NETWORK=4G;INTERNET=connected;RSRP=-97;SINR=9;RSSI=-51;SMS_STORED=63;SMS_MAX=500" "$out" "$?"
    done

    # --- errors ---------------------------------------------------------------
    start_router nosim
    out="$(run bash "$S" status)"; check "SIM card missing" 1 "DETAIL=SIM card missing" "$out" "$?"
    start_router badpw
    out="$(run bash "$S" status)"; check "wrong password" 1 "wrong username or password (code 108006)" "$out" "$?"
    out="$(env HUAWEI_CONFIG=/nonexistent HUAWEI_PASSWORD=x HUAWEI_ROUTER_URL=https://127.0.0.1:1 bash "$S" status 2>/dev/null)"
    check "router unreachable" 1 "DETAIL=router unreachable" "$out" "$?"
    start_router sha256
    out="$(run env HUAWEI_PASSWORD= bash "$S" status)"; check "no password configured" 1 "DETAIL=no password configured" "$out" "$?"

    # --- one session at a time --------------------------------------------------
    start_router flaky
    out="$(run bash "$S" status)"; check "session rejected once, new try succeeds" 0 "STATUS=OK;SIGNAL=4/5" "$out" "$?"
    start_router single
    runs=()
    for i in 1 2 3; do
        run env HUAWEI_LOCK_DIR="$WORK/lock" bash "$S" send "+3361111111$i" "parallel $i" > "$WORK/parallel-$i" &
        runs+=($!)
    done
    wait "${runs[@]}"     # only these runs: the simulated routers keep running
    check "3 runs at the same time wait for each other" 0 "3 sent" "$(cat "$WORK"/parallel-* | grep -c 'SENT=1/1') sent" 0
    check "lock released after the runs" 0 "absent" "$([[ -e "$WORK/lock" ]] && echo present || echo absent)" 0

    # --- send -----------------------------------------------------------------
    start_router sha256
    out="$(run bash "$S" send +33611111111 'Alert <&> été')"; check "send one SMS" 0 "STATUS=OK;SMS=sent;SENT=1/1" "$out" "$?"
    sent="$(cat "$LOGS/sent.log")"
    check "message XML-escaped, length in characters" 0 "+33611111111|Alert &lt;&amp;&gt; été|13" "$sent" 0
    out="$(run bash "$S" send +33611111111,+33622222222 +33611111111 +33633333333 hello)"
    check "several numbers, duplicates removed" 0 "SENT=3/3" "$out" "$?"
    out="$(run bash "$S" +33611111111 short)"; check "short form" 0 "SENT=1/1" "$out" "$?"
    out="$(run bash "$S" send +33611111111 +33699999999 hello)"
    check "one number refused, the other sent" 1 "SMS refused for +33699999999 (code 113004);SENT=1/2" "$out" "$?"
    printf '+33644444444\n+33655555555\n' > "$WORK/recipients"
    out="$(echo "Water leak" | run env HUAWEI_SMS_TO=+33655555555,+33666666666 HUAWEI_SMS_TO_FILE="$WORK/recipients" bash "$S" send default -)"
    check "default recipients (config + file) and stdin message" 0 "SENT=3/3" "$out" "$?"
    check "stdin message content" 0 "+33666666666|Water leak|10" "$(cat "$LOGS/sent.log")" 0
    out="$(run bash "$S" send default hello)"; check "default without recipients" 1 "DETAIL=no recipient" "$out" "$?"

    # --- rate limit -------------------------------------------------------------
    rm -f -- "$WORK/sent-state"
    out="$(run env HUAWEI_SMS_LIMIT=3 bash "$S" send +33611111111 +33622222222 a)"; check "rate limit: 2 of 3" 0 "SENT=2/2" "$out" "$?"
    out="$(run env HUAWEI_SMS_LIMIT=3 bash "$S" send +33611111111 +33622222222 b)"; check "rate limit: partly sent" 3 "SENT=1/2;LIMITED=1" "$out" "$?"
    out="$(run env HUAWEI_SMS_LIMIT=3 bash "$S" send +33611111111 c)"; check "rate limit: nothing sent" 3 "SENT=0/1;LIMITED=1" "$out" "$?"
    rm -f -- "$WORK/sent-state"

    # --- inbox ----------------------------------------------------------------
    start_router sha256
    out="$(run bash "$S" inbox)"; code=$?
    check "inbox: unread SMS as JSON" 0 '{"index":"40001","from":"+33611111111","date":"2026-11-04 21:00:00","text":"STATUS"}' "$out" "$code"
    check "inbox: XML and JSON escaping" 0 '"text":"Lights off & thanks été \"ok\""' "$out" "$code"
    check "inbox: count" 0 "STATUS=OK;COUNT=2" "$out" "$code"
    out="$(run bash "$S" inbox)"; check "inbox: messages returned only once" 0 "STATUS=OK;COUNT=0" "$out" "$?"

    # --- maintenance ------------------------------------------------------------
    start_router sha256
    out="$(run bash "$S" cleanup)"; check "cleanup: read and sent SMS deleted (2 pages)" 0 "STATUS=OK;DELETED=61" "$out" "$?"
    out="$(run bash "$S" status)"; check "cleanup: unread SMS kept" 0 "SMS_STORED=2" "$out" "$?"
    out="$(run bash "$S" reboot)"; check "reboot" 0 "STATUS=OK;REBOOT=requested" "$out" "$?"
    check "reboot command sent to the router" 0 "1" "$(cat "$LOGS/control.log")" 0
    logins="$(grep -c '/api/user/login' "$LOGS/calls.log")"
    logouts="$(grep -c '/api/user/logout' "$LOGS/calls.log")"
    check "logout after every run except reboot" 0 "$(( logins - 1 ))" "$logouts" 0
done

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
