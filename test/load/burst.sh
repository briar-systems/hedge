#!/usr/bin/env bash
# a burst of QUIC handshakes past the server's crypto rate
#
# hedge#232: several thousand QUIC handshakes dialled at once used to lose some
# to their handshake timeout, and hedge#231 killed a fraction of a burst of a
# few hundred after their requests were already sent. Both had one cause: the
# handshake crypto ran inside the receive path, so the pump read the socket at
# the crypto rate, the kernel receive buffer became an invisible admission queue
# and the handshake deadline counted the time spent in it. Admission is now
# bounded and deferred (hedge#164), so this lane dials a burst the server cannot
# finish inside the handshake deadline and asserts the shape that follows:
#
#   every dial is either completed or refused before the server spends a
#   handshake on it: nothing is admitted and then lost, so every handshake the
#   server completed is a connection the client saw, and what it promoted but
#   did not complete is only what was still in flight when the client's own
#   budget ran out
#
#   the socket drops nothing: the pump reads at read speed, so the kernel
#   receive queue never fills and its drop counter stays where it started
#
#   completions match the service rate: with every dial arriving at once, what
#   completes is what the deadline and the running per-handshake cost say can,
#   so the connected count is the measured service rate over the refusal
#   horizon, within a stated tolerance
#
# the verdict is a ratio taken inside one run, never a duration, so it says the
# same thing on a fast machine and a loaded one.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
# the warm-up measures the service rate: small enough that every dial completes
warm="${LOAD_BURST_WARM:-200}"
# the burst is past what the deadline can carry at the measured rate
burst="${LOAD_BURST:-3000}"
# the server's handshake deadline, and the refusal horizon
handshake_ms="${LOAD_BURST_HANDSHAKE_MS:-10000}"
# a refused dial retransmits its Initial and is re-admitted with a fresh
# arrival, so the client budget is longer than the server's deadline
connect_timeout="${LOAD_BURST_CONNECT_TIMEOUT:-30}"
# completions within this fraction of rate x horizon pass
tolerance="${LOAD_BURST_TOLERANCE:-0.35}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19110
SECURE_PORT=19111
QUIC_PORT=19112
ADMIN_PORT=19113

prepare_load
if ! resolve_h3load; then exit 1; fi

export HEDGE_ADMIN_TOKEN=burst-secret
write_config "$work/burst.toml" \
    "max_connections_per_peer = $((burst * 2))
memory_bytes = $((burst * 4 * 1048576))" \
    "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" \
    "handshake_ms = $handshake_ms
keep_alive_ms = 900000
drain_ms = 5000" \
    "[[listener]]
name = \"admin\"
address = \"127.0.0.1:$ADMIN_PORT\"
protocols = [\"http/1.1\"]

[secret.admin-token]
provider = \"env\"
key = \"HEDGE_ADMIN_TOKEN\"

[telemetry]
metrics = true

[admin]
enabled = true
listener = \"admin\"
auth_secret = \"admin-token\"
max_response_bytes = 8192"
start_hedge "$work/burst.toml"

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "warm=$warm burst=$burst handshake_ms=$handshake_ms connect_timeout=${connect_timeout}s"
echo

metric() {
    curl -sS -H "Authorization: Bearer $HEDGE_ADMIN_TOKEN" \
        "http://127.0.0.1:$ADMIN_PORT/metrics" \
        | awk -v name="$1" '$1 == name { print $2; found = 1 }
            END { if (!found) print 0 }'
}

# the kernel's per-socket drop counter, the last column of the socket's row
socket_drops() {
    local port_hex
    port_hex="$(printf '%04X' "$QUIC_PORT")"
    awk -v addr="0100007F:$port_hex" '$2 == addr { print $NF; found = 1 }
        END { if (!found) print "missing" }' /proc/net/udp
}

# a burst of `count` dials at once, every handshake in flight together. prints
# `connected elapsed` from h3load's own report.
dial() {
    local count="$1" label="$2"
    "$h3load" -address "127.0.0.1:$QUIC_PORT" -connections "$count" \
        -connect-timeout "${connect_timeout}s" -serve=false -label "$label" \
        >"$work/$label.out" 2>&1
    awk '/: connected=/ { split($2, c, "[=/]"); sub("s$", "", $4); print c[2], $4 }' \
        "$work/$label.out"
}

drops_before="$(socket_drops)"
test "$drops_before" != missing
report $? "the QUIC socket is visible in /proc/net/udp (drops $drops_before)"

read -r connected elapsed <<<"$(dial "$warm" warm)"
test "$connected" = "$warm"
report $? "a warm-up of $warm dials all connect ($connected in ${elapsed}s)"
rate="$(awk -v n="$connected" -v t="$elapsed" \
    'BEGIN { if (t > 0) printf "%.1f", n / t; else print 0 }')"
echo "service rate ${rate}/s"

promoted_before="$(metric hedge_quic_handshakes_promoted_total)"
completed_before="$(metric hedge_quic_handshakes_completed_total)"
dropped_before="$(metric hedge_quic_handshakes_dropped_total)"
deferred_before="$(metric hedge_quic_handshakes_deferred_total)"
arrivals_before="$(metric hedge_quic_arrivals_dropped_total)"
retries_before="$(metric hedge_quic_retries_dropped_total)"

read -r connected elapsed <<<"$(dial "$burst" burst)"
# the last clients' Finished packets are still on the server's next turns
# when the dialler exits; a handshake abandoned mid-flight stays in flight
# for its whole deadline, so a moment's settling changes nothing else
sleep 1
promoted=$(( $(metric hedge_quic_handshakes_promoted_total) - promoted_before ))
completed=$(( $(metric hedge_quic_handshakes_completed_total) - completed_before ))
dropped=$(( $(metric hedge_quic_handshakes_dropped_total) - dropped_before ))
deferred=$(( $(metric hedge_quic_handshakes_deferred_total) - deferred_before ))
arrivals_dropped=$(( $(metric hedge_quic_arrivals_dropped_total) - arrivals_before ))
retries_dropped=$(( $(metric hedge_quic_retries_dropped_total) - retries_before ))
in_flight="$(metric hedge_quic_handshakes_in_flight)"
drops_after="$(socket_drops)"
echo "burst: dialled=$burst connected=$connected in ${elapsed}s deferred=$deferred promoted=$promoted completed=$completed dropped=$dropped arrivals_dropped=$arrivals_dropped retries_dropped=$retries_dropped in_flight=$in_flight socket_drops=$((drops_after - drops_before))"

# a client counts itself connected on the server's Finished, and one that
# reaches that at the end of its run exits before its own Finished is read,
# so the client's count can exceed the server's by those, never the reverse
test "$completed" -le "$connected"
report $? "every handshake the server completed is a connection the client saw (connected $connected, completed $completed)"

# a promoted handshake the server did not complete was abandoned by a client
# whose own budget ran out while it was in flight, so at the end of the run
# the two counts agree
test "$((promoted - completed))" -le "$in_flight"
report $? "nothing is admitted and then lost: what was promoted but not completed was still in flight (promoted $promoted, completed $completed, in flight $in_flight)"

test "$((connected + dropped))" -ge "$burst"
report $? "every dial completes or is refused before the server spends a handshake on it (connected $connected + dropped $dropped >= $burst)"

test "$drops_after" = "$drops_before"
report $? "the socket drops nothing across the burst ($((drops_after - drops_before)))"

# every dial arrives at once and a refused dial's retransmission arrives afresh
# under its own deadline, so the horizon over which the measured rate can
# complete dials is the client's own budget, capped at the burst itself
expected="$(awk -v r="$rate" -v h="$connect_timeout" -v n="$burst" \
    'BEGIN { e = int(r * h); if (e > n) e = n; print e }')"
awk -v got="$connected" -v want="$expected" -v tol="$tolerance" \
    -v rate="$rate" -v horizon="$connect_timeout" 'BEGIN {
    printf "burst: expected about %d at %s/s over %ss, got %d (%.0f%%)\n",
        want, rate, horizon, got, 100 * got / want
    exit !(got >= want * (1 - tol) && got <= want * (1 + tol))
}'
report $? "completions match the service rate over the refusal horizon within $tolerance"

if stop_hedge; then
    report 0 "hedge stops cleanly after the burst"
else
    failed=$((failed + 1))
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
