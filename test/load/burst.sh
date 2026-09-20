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
#   no token Initial is dropped at the arrival queue (hedge#242): a client that
#   has answered a Retry has paid an RTT and the server a token, so under
#   pressure the queue gives up first flights, negotiations and duplicates
#   before one of those. the queue's drops are reported by class, and the
#   dialler reports how many clients retransmitted a first flight (a drop the
#   server never saw as a client) or a token Initial (a deferral, once token
#   drops are zero) before they were admitted
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
# a dial the server never answers gives up after this; a refused one gives
# up at once, so the budget only bounds a dial that was lost
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

# a labelled row: `metric_class name value` reads name{class="value"}
metric_class() {
    metric "$1{class=\"$2\"}"
}

arrival_classes="token untoken other duplicate"

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

# the clients of a dial that retransmitted an Initial before admission, from
# the dialler's report: `retried first_flight token`
retransmits() {
    awk '/: retried=/ { split($2, r, "="); split($4, f, "="); split($5, t, "=");
        print r[2], f[2], t[2] }' "$work/$1.out"
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

sleep 1
promoted_before="$(metric hedge_quic_handshakes_promoted_total)"
completed_before="$(metric hedge_quic_handshakes_completed_total)"
dropped_before="$(metric hedge_quic_handshakes_dropped_total)"
deferred_before="$(metric hedge_quic_handshakes_deferred_total)"
refused_before="$(metric hedge_quic_handshakes_refused_total)"
retries_before="$(metric hedge_quic_retries_dropped_total)"
declare -A arrivals_before
for class in $arrival_classes; do
    arrivals_before[$class]="$(metric_class hedge_quic_arrivals_dropped_total "$class")"
done
expired_before="$(metric hedge_quic_handshakes_expired_total)"

read -r connected elapsed <<<"$(dial "$burst" burst)"
# the last clients' Finished packets are still on the server's next turns
# when the dialler exits; a handshake abandoned mid-flight stays in flight
# for its whole deadline, so a moment's settling changes nothing else
sleep 1
promoted=$(( $(metric hedge_quic_handshakes_promoted_total) - promoted_before ))
completed=$(( $(metric hedge_quic_handshakes_completed_total) - completed_before ))
dropped=$(( $(metric hedge_quic_handshakes_dropped_total) - dropped_before ))
deferred=$(( $(metric hedge_quic_handshakes_deferred_total) - deferred_before ))
refused=$(( $(metric hedge_quic_handshakes_refused_total) - refused_before ))
retries_dropped=$(( $(metric hedge_quic_retries_dropped_total) - retries_before ))
declare -A arrivals_dropped
arrivals_total=0
for class in $arrival_classes; do
    arrivals_dropped[$class]=$(( $(metric_class hedge_quic_arrivals_dropped_total "$class") - arrivals_before[$class] ))
    arrivals_total=$(( arrivals_total + arrivals_dropped[$class] ))
done
expired=$(( $(metric hedge_quic_handshakes_expired_total) - expired_before ))
in_flight="$(metric hedge_quic_handshakes_in_flight)"
finish_ms="$(awk -v ns="$(metric hedge_quic_handshake_finish_ns)" 'BEGIN { print ns / 1000000 }')"
drops_after="$(socket_drops)"
read -r retried first_flight_retransmits token_retransmits <<<"$(retransmits burst)"
echo "burst: dialled=$burst connected=$connected in ${elapsed}s deferred=$deferred promoted=$promoted completed=$completed dropped=$dropped refused=$refused retries_dropped=$retries_dropped in_flight=$in_flight expired=$expired finish_ms=$finish_ms socket_drops=$((drops_after - drops_before))"
echo "burst: arrivals dropped=$arrivals_total token=${arrivals_dropped[token]} untoken=${arrivals_dropped[untoken]} other=${arrivals_dropped[other]} duplicate=${arrivals_dropped[duplicate]}"
echo "burst: clients retried=$retried retransmitted first_flight=$first_flight_retransmits token=$token_retransmits"

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

# a handshake promoted with less time left than a handshake takes spends its
# crypto and expires on its deadline with the client told nothing. the
# promotion rule judges by the measured finish so this never happens
test "$expired" -eq 0
report $? "no promoted handshake expired on its deadline (expired $expired, finish ${finish_ms}ms)"

# a dial the deadline drops at the queue and one the ceiling refuses on
# arrival both cost the server no handshake
test "$((connected + dropped + refused))" -ge "$burst"
report $? "every dial completes or is refused before the server spends a handshake on it (connected $connected + dropped $dropped + refused $refused >= $burst)"

test "$drops_after" = "$drops_before"
report $? "the socket drops nothing across the burst ($((drops_after - drops_before)))"

test "${arrivals_dropped[token]}" -eq 0
report $? "no token Initial is dropped at the arrival queue (token ${arrivals_dropped[token]}, untoken ${arrivals_dropped[untoken]}, other ${arrivals_dropped[other]}, duplicate ${arrivals_dropped[duplicate]})"

# every dial arrives at once and a refused dial is gone, so the horizon over
# which the measured rate can complete dials is the server's own handshake
# deadline, capped at the burst itself
horizon="$(awk -v ms="$handshake_ms" 'BEGIN { print ms / 1000 }')"
expected="$(awk -v r="$rate" -v h="$horizon" -v n="$burst" \
    'BEGIN { e = int(r * h); if (e > n) e = n; print e }')"
awk -v got="$connected" -v want="$expected" -v tol="$tolerance" \
    -v rate="$rate" -v horizon="$horizon" 'BEGIN {
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
