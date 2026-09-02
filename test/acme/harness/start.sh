#!/bin/sh
# start the live acme stack: pebble, its challenge test server, and the plain
# http front end. every process is local and bound to loopback.
#
# challtestsrv's http-01 and tls-alpn-01 responders are disabled. answering
# those challenges is what this suite is proving hedge does, so ports 5001 and
# 5002 belong to hedge listeners and nothing else may hold them.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tools="$root/.tools"
bin="$tools/gopath/bin"
run="$tools/run"
mkdir -p "$run"

"$(dirname -- "$0")/build.sh"

"$0.stop" 2>/dev/null || true

# -http01 "" and -tlsalpn01 "" are load bearing, not tidying: restoring either
# responder would make its suite pass whether or not hedge served a byte.
#
# -defaultIPv6 "" is load bearing too: challtestsrv answers AAAA with ::1 by
# default, and the authority follows it to a listener that is not there. the
# failure looks like hedge not answering.
#
# challtestsrv still answers dns for the names under test, and still exposes
# its management api so a dns-01 provider can publish a record.
"$bin/pebble-challtestsrv" \
    -http01 "" -tlsalpn01 "" -https01 "" \
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
