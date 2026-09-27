#!/usr/bin/env bash
# a sustained keep-alive rate, with no datagram dropped
#
# #274's cell: LOAD_KEEPALIVE QUIC connections (10000) each send a keep-alive
# PING every LOAD_KEEPALIVE_PERIOD seconds (1), so the QUIC socket takes a
# known datagram rate, count over period, that a real deployment reaches with
# clients on a one-second keep-alive. Every PING costs the server a receive, an
# ACK and its send. #269 measured the socket dropping 76,396 datagrams over a
# hold at this rate, and a CONNECTION_CLOSE dropped at release leaves its
# connection live until the idle timeout (#296).
#
# The connections are dialled at LOAD_KEEPALIVE_RATE a second (250), at most 64
# at a time: the PINGs of the connections already held arrive throughout the
# dial, and a burst of handshakes on top of them would measure the handshake
# rate, which burst.sh does, rather than the keep-alive rate. Once every one is
# held and a period has passed, so each is on its cadence, the socket's
# drop counter is read over LOAD_KEEPALIVE_SECONDS (10). It passes when every
# dial is held, the socket dropped nothing over the window, and every
# connection has left hedge once the holder closes them. It prints the
# server's CPU per PING round, the cores it used and the receive queue's peak.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
count="${LOAD_KEEPALIVE:-10000}"
period="${LOAD_KEEPALIVE_PERIOD:-1}"
window="${LOAD_KEEPALIVE_SECONDS:-10}"
rate="${LOAD_KEEPALIVE_RATE:-250}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19180
SECURE_PORT=19181
QUIC_PORT=19182
ADMIN_PORT=19183

prepare_load
if ! resolve_h3load; then exit 1; fi

# CPU time of every thread of the served process, in nanoseconds
cpu_ns() {
    awk '{ sum += $1 } END { printf "%d", sum }' /proc/"$hedge_pid"/task/*/schedstat
}

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "count=$count period=${period}s rate=$((count / period))/s window=${window}s dials=$rate/s"
echo

export HEDGE_ADMIN_TOKEN=keepalive-secret
write_config "$work/keepalive.toml" \
    "max_connections_per_peer = $((count * 2))
memory_bytes = $((count * 4 * 1048576))" \
    "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" \
    "keep_alive_ms = 900000" \
    "$(admin_config)"
start_hedge "$work/keepalive.toml"
start_socket_sampler "$QUIC_PORT"

mark="$(socket_mark "$QUIC_PORT")"
start_holder keepalive "$h3load" -address "127.0.0.1:$QUIC_PORT" \
    -connections "$count" -serve=false -rate "$rate" -dialing 64 \
    -connect-timeout 60s -idle-timeout 900s -keep-alive "${period}s" \
    -source 127.0.0.2 -label keepalive -hold
held="$(held_by keepalive "${holders[0]}")"
echo "dial: held ${held:-none}, socket $(socket_phase "$QUIC_PORT" "$mark")"
test "${held:-0}" = "$count"
report $? "every one of $count dials is held"

sleep "$period"
mark="$(socket_mark "$QUIC_PORT")"
before="$(cpu_ns)"
sleep "$window"
after="$(cpu_ns)"
phase="$(socket_phase "$QUIC_PORT" "$mark")"
awk -v n="$count" -v p="$period" -v w="$window" -v c="$((after - before))" 'BEGIN {
    printf "hold: %d/s for %ds, %.3f cores, %.1f us per round\n", n / p, w, c / (w * 1e9), c / (n * w / p) / 1000
}'
echo "hold: socket $phase"
drops="${phase#drops=}"
drops="${drops%% *}"
test "$drops" = 0
report $? "the socket dropped no datagram at $((count / period)) keep-alives a second ($drops)"

mark="$(socket_mark "$QUIC_PORT")"
release_holders
live="$(quic_released)"
released=$?
report "$released" "every connection leaves once its client closes it ($live live, socket $(socket_phase "$QUIC_PORT" "$mark"))"

stop_socket_sampler
if ! stop_hedge; then failed=$((failed + 1)); fi

echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
