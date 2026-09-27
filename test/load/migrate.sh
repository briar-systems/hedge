#!/usr/bin/env bash
# a QUIC connection survives its client rebinding to a new port
#
# #169 section 8's migration cell: LOAD_MIGRATE connections each complete a
# request, move their socket to a new local port with no PATH_CHALLENGE of
# their own (what a NAT rebinding looks like to the server), and complete a
# second request on the same connection. It passes only if hedge follows every
# connection to its new address. LOAD_MIGRATE_WORKERS workers (4) serve, each
# binding the QUIC port, and the kernel hashes the new 4-tuple to any of their
# sockets: a datagram that lands on a worker other than its connection's is
# handed over by connection ID (#174). The cell prints the fraction of
# datagrams handed over, from hedge's own counters.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
count="${LOAD_MIGRATE:-32}"
workers="${LOAD_MIGRATE_WORKERS:-4}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19170
SECURE_PORT=19171
QUIC_PORT=19172
ADMIN_PORT=19173

prepare_load
if ! resolve_h3load; then exit 1; fi

export HEDGE_ADMIN_TOKEN=migrate-secret
write_config "$work/migrate.toml" "max_connections_per_peer = $((count * 4))" \
    "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" "" "$(admin_config)" "$workers"
start_hedge "$work/migrate.toml"

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "connections=$count workers=$workers"
echo

"$h3load" -address "127.0.0.1:$QUIC_PORT" -connections "$count" -migrate \
    -path /small -body-bytes "$SMALL_BYTES" -connect-timeout 10s -label migrate \
    >"$work/migrate.out" 2>&1
status=$?
cat "$work/migrate.out"
report "$status" "every one of $count QUIC connections is served before and after its client rebinds its port"

received="$(metric hedge_quic_datagrams_received_total)"
forwarded="$(metric 'hedge_quic_forwarded_total{direction="in"}')"
dropped=0
for reason in ring_full slab_full stopped; do
    value="$(metric "hedge_quic_forward_dropped_total{reason=\"$reason\"}")"
    dropped=$((dropped + ${value/missing/0}))
done
unroutable="$(metric hedge_quic_unroutable_total)"
awk -v r="$received" -v f="$forwarded" -v d="$dropped" -v u="$unroutable" 'BEGIN {
    printf "forwarded: %d of %d datagrams received (%.1f%%), %d dropped forwarding, %d unroutable\n", f, r, r ? 100 * f / r : 0, d, u
}'

if stop_hedge; then
    report 0 "hedge stops cleanly after the migrations"
else
    failed=$((failed + 1))
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
