#!/usr/bin/env bash
# a steady rate of connect, request and close, with flat memory and CPU
#
# #169 section 8's churn cell: for LOAD_CHURN_SECONDS (10 minutes by default)
# connections arrive at a fixed rate, each carries one request and closes, so
# the server admits and retires LOAD_CHURN_TLS_RATE (or LOAD_CHURN_H3_RATE)
# connections a second the whole time. The client (test/load/rate in churn
# mode) is open-loop, so a slow server shows as missed starts rather than a
# lower rate, and it samples the served process's CPU time every
# LOAD_CHURN_SAMPLE seconds.
#
# The run is two phases of half the time each against one server, and after
# each the lane waits for every connection to leave and reads the resident
# set at rest. It passes when every connection is served with no failure and
# no missed start, the resident set at rest after the second phase is within
# LOAD_CHURN_RSS_MARGIN bytes of what it was after the first, and the CPU per
# connection over the second phase's second half is within
# LOAD_CHURN_CPU_TOLERANCE percent of the first phase's (each phase's first
# half is warm-up). A record, a timer entry or a pool chunk that a retired
# connection leaves behind grows the resident set at rest linearly in the
# connections served and fails the first; a walk over anything that grows the
# same way fails the second.
#
# The resident set under load is not compared. It holds every connection still
# live, and a QUIC connection stays live through its draining period after its
# client closes, so the live count and the pools sized to it move with how the
# closes happen to bunch up, not with what connections leave behind.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
seconds="${LOAD_CHURN_SECONDS:-600}"
sample="${LOAD_CHURN_SAMPLE:-10}"
protocols="${LOAD_CHURN_PROTOCOLS:-tls h3}"
tls_rate="${LOAD_CHURN_TLS_RATE:-200}"
h3_rate="${LOAD_CHURN_H3_RATE:-100}"
in_flight="${LOAD_CHURN_IN_FLIGHT:-256}"
rss_margin="${LOAD_CHURN_RSS_MARGIN:-4194304}"
cpu_tolerance="${LOAD_CHURN_CPU_TOLERANCE:-25}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19160
SECURE_PORT=19161
QUIC_PORT=19162
ADMIN_PORT=19163
export HEDGE_ADMIN_TOKEN=churn-secret

prepare_load
if ! resolve_go_tool rate; then exit 1; fi
rate_tool="$tool"
thp_off

# one phase of churn, its samples in $work/churn-<protocol>-<phase>.out
phase() {
    local protocol="$1" rate="$2" address="$3" part="$4" seconds="$5"
    "$rate_tool" -address "$address" -protocol "$protocol" -mode churn \
        -rate "$rate" -connections "$in_flight" -duration "${seconds}s" \
        -sample "${sample}s" -path /small -body-bytes "$SMALL_BYTES" \
        -server-pid "$hedge_pid" -clock-ticks "$(getconf CLK_TCK)" \
        -label "churn-$protocol-$part" >"$work/churn-$protocol-$part.out" 2>&1
    local status=$?
    grep -v ': sample ' "$work/churn-$protocol-$part.out"
    return "$status"
}

# waits for every connection of a phase to leave: a QUIC connection through
# its draining period, a TCP or TLS one until its socket is closed
at_rest() {
    local protocol="$1" idle="$2"
    if [ "$protocol" = h3 ]; then quic_released >/dev/null; else sockets_released "$idle" >/dev/null; fi
}

# CPU seconds per connection over the second half of a phase's samples, and
# the most connections it held open at once. samples are cumulative
phase_cost() {
    awk '
        / sample / {
            for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
            n++; ok[n] = v["ok"]; cpu[n] = v["server_cpu"]; open[n] = v["in_flight_peak"]
        }
        END {
            if (n < 5) { print "too few samples"; exit 1 }
            half = int(1 + (n - 1) / 2)
            for (i = 1; i <= n; i++) if (open[i] > peak) peak = open[i]
            printf "%.9f %d\n", (cpu[n] - cpu[half]) / (ok[n] - ok[half]), peak
        }' "$1"
}

churn() {
    local protocol="$1" rate="$2" address idle half status rest1 rest2 cost1 cost2
    address="127.0.0.1:$SECURE_PORT"
    if [ "$protocol" = h3 ]; then address="127.0.0.1:$QUIC_PORT"; fi
    if [ "$protocol" = h1 ]; then address="127.0.0.1:$CLEARTEXT_PORT"; fi
    write_config "$work/churn.toml" \
        "max_connections_per_peer = 65536" \
        "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" "" "$(admin_config)"
    start_hedge "$work/churn.toml"
    idle="$(sockets)"
    half=$((seconds / 2))

    phase "$protocol" "$rate" "$address" 1 "$half"
    status=$?
    at_rest "$protocol" "$idle"
    status=$((status | $?))
    rest1="$(resident)"
    phase "$protocol" "$rate" "$address" 2 "$half"
    status=$((status | $?))
    at_rest "$protocol" "$idle"
    status=$((status | $?))
    rest2="$(resident)"
    report "$status" "$protocol: every one of ${seconds}s of connections at $rate/s is served, none missed, and all leave"

    cost1="$(phase_cost "$work/churn-$protocol-1.out")"
    cost2="$(phase_cost "$work/churn-$protocol-2.out")"
    awk -v r1="$rest1" -v r2="$rest2" -v c1="${cost1% *}" -v c2="${cost2% *}" \
        -v o1="${cost1#* }" -v o2="${cost2#* }" -v p="$protocol" \
        -v served=$((half * rate)) 'BEGIN {
        printf "%s: resident at rest after the first phase=%d after the second=%d (%+d, %+.1f bytes per connection served), CPU per connection first phase=%.1fus second=%.1fus, most open at once %d and %d\n",
            p, r1, r2, r2 - r1, (r2 - r1) / served, c1 * 1e6, c2 * 1e6, o1, o2
    }'
    test "$rest2" -le $((rest1 + rss_margin))
    report $? "$protocol: the resident set at rest does not grow with the connections served (margin $rss_margin bytes)"
    awk -v a="${cost1% *}" -v b="${cost2% *}" -v tol="$cpu_tolerance" 'BEGIN { exit !(a > 0 && b <= a * (1 + tol / 100)) }'
    report $? "$protocol: CPU per connection is flat across the run (within $cpu_tolerance%)"
    if ! stop_hedge; then failed=$((failed + 1)); fi
    echo
}

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "seconds=$seconds sample=${sample}s tls_rate=$tls_rate/s h3_rate=$h3_rate/s in_flight=$in_flight"
echo

for protocol in $protocols; do
    case "$protocol" in
        tls) churn tls "$tls_rate" ;;
        h1)  churn h1 "$tls_rate" ;;
        h3)  churn h3 "$h3_rate" ;;
        *) echo "unknown protocol $protocol"; failed=$((failed + 1)) ;;
    esac
done

echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
