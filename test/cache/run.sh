#!/usr/bin/env bash
# cache conformance over the real hedge binary and a counted socket origin

set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1

binary="${HEDGE_BINARY:-out/linux-x86_64/debug/bin/hedge}"
work="$(mktemp -d)"
origin_pid=""
hedge_pid=""

stop_processes() {
    stop_hedge >/dev/null 2>&1 || true
    if [ -n "$origin_pid" ] && kill -0 "$origin_pid" 2>/dev/null; then
        kill "$origin_pid" 2>/dev/null
        wait "$origin_pid" 2>/dev/null
    fi
    rm -rf "$work"
}
trap stop_processes EXIT

passed=0
failed=0

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "pass    $name"
        passed=$((passed + 1))
    else
        echo "FAILED  $name (expected '$expected', got '$actual')"
        failed=$((failed + 1))
    fi
}

stop_hedge() {
    if [ -z "$hedge_pid" ]; then return 0; fi
    local pid="$hedge_pid"
    hedge_pid=""
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || return 1
        if ! timeout 10s tail --pid="$pid" -f /dev/null; then
            echo "FAILED  hedge did not stop within 10 seconds"
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            cat "$work/hedge.log"
            return 1
        fi
    fi
    local status=0
    wait "$pid" 2>/dev/null || status=$?
    if [ "$status" -ne 0 ]; then
        echo "FAILED  hedge exited with status $status"
        cat "$work/hedge.log"
        return 1
    fi
    return 0
}

start_hedge() {
    if ! stop_hedge; then return 1; fi
    "$binary" test/cache/hedge.toml >"$work/hedge.log" 2>&1 &
    hedge_pid=$!
    for _ in $(seq 50); do
        if grep -q '^hedge: ready' "$work/hedge.log" 2>/dev/null; then return 0; fi
        if ! kill -0 "$hedge_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    cat "$work/hedge.log"
    return 1
}

python3 test/cache/origin.py 19091 >"$work/origin.log" 2>&1 &
origin_pid=$!
for _ in $(seq 50); do
    if timeout 1 bash -c '</dev/tcp/127.0.0.1/19091' 2>/dev/null; then break; fi
    if ! kill -0 "$origin_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if ! kill -0 "$origin_pid" 2>/dev/null; then
    cat "$work/origin.log"
    exit 1
fi

start_hedge || exit 1

item="$(python3 test/cache/client.py item)"
check "an origin 304 becomes a stored 200" 200 "$(cut -d/ -f1 <<<"$item")"
check "the refreshed entry is fresh on its next request" 200 \
    "$(cut -d/ -f2 <<<"$item")"
check "the internally validated body is unchanged" representation \
    "$(cut -d/ -f3 <<<"$item")"
check "304 fields replace and absent stored fields persist" '"v1"/new/preserved' \
    "$(cut -d/ -f4-6 <<<"$item")"
check "qualified private fields are removed on refresh" absent \
    "$(cut -d/ -f7 <<<"$item")"

start_hedge || exit 1
covered="$(python3 test/cache/client.py covered)"
check "stale-if-error replaces a nonempty origin 502" 200 "$(cut -d/ -f1 <<<"$covered")"
check "stale-if-error exposes only the stored bytes" 'covered stale' \
    "$(cut -d/ -f2 <<<"$covered")"
leak="$(python3 test/cache/client.py leak)"
check "synthetic validators do not reach the next request" 'clean request' \
    "$(cut -d/ -f2 <<<"$leak")"

start_hedge || exit 1
check "an origin 502 survives without stale-if-error" 502 \
    "$(python3 test/cache/client.py refused)"

start_hedge || exit 1
multi="$(python3 test/cache/client.py multi)"
check "multiple ranges deliberately receive a full response" 200 \
    "$(cut -d/ -f1 <<<"$multi")"
check "the full representation is byte-identical" 0123456789 \
    "$(cut -d/ -f2 <<<"$multi")"

counts="$(curl -sS http://127.0.0.1:19091/counts | python3 -c '
import json, sys
d = json.load(sys.stdin)
r, c = d["requests"], d["conditionals"]
print("%d/%d/%d/%d/%d/%d/%d/%d/%d" % (
    r.get("/item", 0), c.get("/item", 0),
    r.get("/error-covered", 0), c.get("/error-covered", 0),
    r.get("/error-refused", 0), c.get("/error-refused", 0),
    r.get("/leak", 0), c.get("/leak", 0),
    r.get("/multi", 0)))
')"
check "origin counts prove hits, revalidation, and failure attempts" \
    "2/1/2/1/2/1/1/0/1" "$counts"

if stop_hedge; then
    echo "pass    hedge stops cleanly within 10 seconds"
    passed=$((passed + 1))
else
    failed=$((failed + 1))
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
