#!/usr/bin/env bash
# a QUIC connection survives its client rebinding to a new port
#
# #169 section 8's migration cell: LOAD_MIGRATE connections each complete a
# request, move their socket to a new local port with no PATH_CHALLENGE of
# their own (what a NAT rebinding looks like to the server), and complete a
# second request on the same connection. It passes only if hedge follows every
# connection to its new address. With workers steering datagrams by
# connection ID (#174), the new 4-tuple can land on another worker's socket,
# which is the case this cell exists to hold.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
count="${LOAD_MIGRATE:-32}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19170
SECURE_PORT=19171
QUIC_PORT=19172

prepare_load
if ! resolve_h3load; then exit 1; fi

write_config "$work/migrate.toml" "max_connections_per_peer = $((count * 4))" \
    "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT"
start_hedge "$work/migrate.toml"

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "connections=$count"
echo

"$h3load" -address "127.0.0.1:$QUIC_PORT" -connections "$count" -migrate \
    -path /small -body-bytes "$SMALL_BYTES" -connect-timeout 10s -label migrate \
    >"$work/migrate.out" 2>&1
status=$?
cat "$work/migrate.out"
report "$status" "every one of $count QUIC connections is served before and after its client rebinds its port"

if stop_hedge; then
    report 0 "hedge stops cleanly after the migrations"
else
    failed=$((failed + 1))
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
