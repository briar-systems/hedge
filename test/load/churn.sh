#!/usr/bin/env bash
# a steady rate of connect, request and close, with flat memory and CPU
#
# #169 section 8's churn cell: for LOAD_CHURN_SECONDS (10 minutes by default)
# connections arrive at a fixed rate, each carries one request and closes, so
# the server admits and retires LOAD_CHURN_TLS_RATE (or LOAD_CHURN_H3_RATE)
# connections a second the whole time. The client (test/load/rate in churn
# mode) is open-loop, so a slow server shows as missed starts rather than a
# lower rate, and it samples the served process's resident set and CPU time
# every LOAD_CHURN_SAMPLE seconds.
#
# It passes when every connection is served with no failure and no missed
# start, the resident set over the second half of the run peaks no higher than
# it did over the first half plus LOAD_CHURN_RSS_MARGIN bytes, and the CPU per
# connection over the last quarter is within LOAD_CHURN_CPU_TOLERANCE percent
# of the second quarter's (the first is warm-up). A record, a timer entry or a
# pool chunk that a retired connection leaves behind grows the resident set
# linearly in the connections served and fails the first; a walk over
# anything that grows the same way fails the second.

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

prepare_load
if ! resolve_go_tool rate; then exit 1; fi
rate_tool="$tool"

churn() {
    local protocol="$1" rate="$2" address out="$work/churn-$1.out"
    address="127.0.0.1:$SECURE_PORT"
    if [ "$protocol" = h3 ]; then address="127.0.0.1:$QUIC_PORT"; fi
    if [ "$protocol" = h1 ]; then address="127.0.0.1:$CLEARTEXT_PORT"; fi
    write_config "$work/churn.toml" \
        "max_connections_per_peer = 65536" \
        "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT"
    start_hedge "$work/churn.toml"

    "$rate_tool" -address "$address" -protocol "$protocol" -mode churn \
        -rate "$rate" -connections "$in_flight" -duration "${seconds}s" \
        -sample "${sample}s" -path /small -body-bytes "$SMALL_BYTES" \
        -server-pid "$hedge_pid" -clock-ticks "$(getconf CLK_TCK)" \
        -label "churn-$protocol" >"$out" 2>&1
    local status=$?
    grep -v ': sample ' "$out"
    report "$status" "$protocol: every one of ${seconds}s of connections at $rate/s is served, none missed"

    # samples are cumulative: t, ok and server CPU seconds and the resident set
    # at each. the first half's peak against the second's, and CPU per
    # connection in the second quarter against the last
    awk -v margin="$rss_margin" -v tol="$cpu_tolerance" -v p="$protocol" '
        / sample / {
            for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
            n++; t[n] = v["t"]; ok[n] = v["ok"]; cpu[n] = v["server_cpu"]; rss[n] = v["rss"]
        }
        function at(f) { i = int(1 + (n - 1) * f); return i }
        END {
            if (n < 5) { print p ": too few samples to judge"; exit 1 }
            half = at(0.5)
            for (i = 1; i <= n; i++) {
                if (i <= half && rss[i] > early) early = rss[i]
                if (i > half && rss[i] > late) late = rss[i]
            }
            q1 = at(0.25); q2 = at(0.5); q3 = at(0.75)
            second = (cpu[q2] - cpu[q1]) / (ok[q2] - ok[q1])
            last = (cpu[n] - cpu[q3]) / (ok[n] - ok[q3])
            printf "%s: resident peak first half=%d second half=%d (%+d), CPU per connection second quarter=%.1fus last quarter=%.1fus\n",
                p, early, late, late - early, second * 1e6, last * 1e6
            rss_ok = late <= early + margin
            cpu_ok = last <= second * (1 + tol / 100)
            print (rss_ok ? "rss flat" : "rss grew"), (cpu_ok ? "cpu flat" : "cpu grew")
            exit !(rss_ok && cpu_ok)
        }' "$out" >"$work/churn-$protocol.verdict"
    head -1 "$work/churn-$protocol.verdict"
    grep -q 'rss flat' "$work/churn-$protocol.verdict"
    report $? "$protocol: the resident set is flat across the run (margin $rss_margin bytes)"
    grep -q 'cpu flat' "$work/churn-$protocol.verdict"
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
