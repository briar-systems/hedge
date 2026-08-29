#!/bin/sh
# start the live acme stack: pebble, its challenge test server, and the plain
# http front end. every process is local and bound to loopback.
#
# challtestsrv's own http-01 responder is disabled. answering http-01 is what
# this suite is proving hedge does, so port 5002 belongs to hedge's listener
# and nothing else may hold it.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tools="$root/.tools"
bin="$tools/gopath/bin"
run="$tools/run"
mkdir -p "$run"

"$(dirname -- "$0")/build.sh"

"$0.stop" 2>/dev/null || true

# challtestsrv still answers dns for the names under test, and still exposes
# its management api so a dns-01 provider can publish a record.
# every name resolves to loopback ipv4 only. hedge's test listener binds
# 127.0.0.1, and an AAAA answer would send the authority to ::1 instead.
"$bin/pebble-challtestsrv" \
    -http01 "" -tlsalpn01 ":5001" -https01 "" \
    -defaultIPv6 "" \
    -dnsserver ":8053" -doh "" -management ":8055" \
    >"$run/challtestsrv.log" 2>&1 &
echo $! >"$run/challtestsrv.pid"

# PEBBLE_VA_NOSLEEP removes the randomized validation delay so the suite is
# deterministic. PEBBLE_WFE_NONCEREJECT=0 disables the 5% random badNonce
# injection. PEBBLE_AUTHZREUSE=0 stops the authority handing back an
# authorization an earlier run already validated, so every run answers a
# challenge for real.
cd "$tools"
PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 PEBBLE_AUTHZREUSE=0 \
    "$bin/pebble" -config "$tools/test/config/pebble-config.json" \
    -dnsserver 127.0.0.1:8053 \
    >"$run/pebble.log" 2>&1 &
echo $! >"$run/pebble.pid"

"$bin/acme-proxy" -listen 127.0.0.1:14001 -upstream 127.0.0.1:14000 \
    >"$run/proxy.log" 2>&1 &
echo $! >"$run/proxy.pid"

i=0
while [ "$i" -lt 100 ]; do
    if [ "$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:14001/dir 2>/dev/null)" = "200" ]; then
        echo "live acme stack ready on http://127.0.0.1:14001/dir"
        exit 0
    fi
    i=$((i + 1))
    sleep 0.1
done
echo "live acme stack failed to become ready" >&2
exit 1
