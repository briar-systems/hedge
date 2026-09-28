#!/usr/bin/env bash
# the handoff under load (#299): a listener one worker accepts for, handing
# each connection to the least loaded worker (#173)
#
# On Linux a TCP listener spreads through SO_REUSEPORT, so a local listener is
# the one that takes the handoff there. Each cell runs against a fresh server
# at each count in LOAD_HANDOFF_WORKERS, once over a local socket and once over
# TCP on the same machine, which is the reuseport lane it is compared against:
#
#   requests: HTTP/1.1 requests back to back on LOAD_HANDOFF_CONNECTIONS held
#   connections, so the rate is what the spread of those connections serves
#
#   connections: a fresh connection per request, closed-loop with as many in
#   flight, so every operation is an accept and, over the local socket, a
#   handoff
#
# hedge counts the connections each worker served from a listener that hands
# off (hedge_handoff_served_total{worker}) and those a full inbox left with the
# acceptor (hedge_handoff_kept_total), read from an admin listener before the
# server stops. With more than one worker, every worker has to have
# served at least LOAD_HANDOFF_SPLIT of an even share. A rate at N workers has
# to reach a fraction of N over the first count times the first count's rate,
# up to the host's core count, over either transport: LOAD_HANDOFF_EFFICIENCY
# for requests and LOAD_HANDOFF_ACCEPT_EFFICIENCY for connections, since one
# worker accepts every local connection and that bounds how far they scale.
# LOAD_HANDOFF_CELLS picks the cells.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
connections="${LOAD_HANDOFF_CONNECTIONS:-64}"
duration="${LOAD_HANDOFF_DURATION:-10}"
warmup="${LOAD_HANDOFF_WARMUP:-2}"
worker_counts="${LOAD_HANDOFF_WORKERS:-1 2 4 8}"
efficiency="${LOAD_HANDOFF_EFFICIENCY:-0.7}"
accept_efficiency="${LOAD_HANDOFF_ACCEPT_EFFICIENCY:-0.5}"
split="${LOAD_HANDOFF_SPLIT:-0.5}"
cells="${LOAD_HANDOFF_CELLS:-requests connections}"
transports="local tcp"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19190
SECURE_PORT=19191
QUIC_PORT=19192
ADMIN_PORT=19193
HEDGE_ADMIN_TOKEN="handoff-$$-$RANDOM"
export HEDGE_ADMIN_TOKEN

prepare_load
if ! resolve_go_tool rate; then exit 1; fi
rate_tool="$tool"

# a server with a local listener at `socket` beside the lane's usual ones, at
# `workers` workers. the budget and the per-peer limit admit the whole load
start_handoff_server() {
    local workers="$1" socket="$2"
    write_config "$work/handoff.toml" \
        "max_connections_per_peer = 65536
memory_bytes = $((connections * 4 * 1048576 + 1073741824))" \
        "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" "" \
        "[[listener]]
name = \"local\"
address = \"$socket\"
transport = \"local\"
protocols = [\"http/1.1\"]

$(admin_config)" \
        "$workers"
    start_hedge "$work/handoff.toml"
}

# runs one cell and prints `rate cpu_us_per_op cores`, with the client's own
# report in <label>.out
run_cell() {
    local transport="$1" cell="$2" label="$3" socket="$4" target
    if [ "$transport" = local ]; then
        target=(-network unix -address "$socket")
    else
        target=(-address "127.0.0.1:$CLEARTEXT_PORT")
    fi
    local out="$work/$label.out" rate cpu
    if ! "$rate_tool" "${target[@]}" -protocol h1 -mode "$cell" \
        -connections "$connections" -path /small -body-bytes "$SMALL_BYTES" \
        -duration "${duration}s" -warmup "${warmup}s" \
        -server-pid "$hedge_pid" -clock-ticks "$(getconf CLK_TCK)" \
        -label "$label" >"$out" 2>&1; then
        cat "$out" >&2
        return 1
    fi
    rate="$(awk '/ rate=/ { for (i = 1; i <= NF; i++) if ($i ~ /^rate=/) { sub("rate=", "", $i); print $i } }' "$out")"
    cpu="$(awk '/ server_cpu=/ { sub("per_op=", "", $3); sub("us$", "", $3); sub("cores=", "", $4); print $3, $4 }' "$out")"
    if [ -z "$rate" ] || [ -z "$cpu" ]; then
        cat "$out" >&2
        return 1
    fi
    echo "$rate $cpu"
}

# the running server's handoff counters, as `kept served...` with one served
# count per worker, or `missing` when it has no handoff series
handoff_served() {
    local workers="$1" index line kept
    kept="$(metric hedge_handoff_kept_total)"
    if [ "$kept" = missing ]; then echo missing; return; fi
    line="$kept"
    for ((index = 0; index < workers; index++)); do
        line="$line $(metric "hedge_handoff_served_total{worker=\"$index\"}")"
    done
    echo "$line"
}

# checks the split of `served` (a kept count, then one count per worker) and
# prints it
check_split() {
    local label="$1" workers="$2" served="$3"
    if [ "$served" = missing ] || [[ "$served" == *missing* ]]; then
        report 1 "$label: hedge reported where the handed-off connections were served"
        return
    fi
    read -r kept counts <<<"$served"
    local total
    total="$(awk -v c="$counts" 'BEGIN { n = split(c, v, " "); for (i = 1; i <= n; i++) t += v[i]; print t }')"
    echo "$label: served by worker $counts, $kept of $total kept by the acceptor with a full inbox"
    awk -v c="$counts" -v w="$workers" -v s="$split" 'BEGIN {
        n = split(c, v, " ")
        if (n != w) exit 1
        for (i = 1; i <= n; i++) t += v[i]
        if (t == 0) exit 1
        for (i = 1; i <= n; i++) if (v[i] < s * t / n) exit 1
    }'
    report $? "$label: every one of $workers workers served at least $split of an even share"
}

# every cell over both transports against a fresh server each, with
# `transport cell rate` lines in rates-<workers>
measure_workers() {
    local workers="$1" transport cell label socket result rate per cores served
    : >"$work/rates-$workers"
    for transport in $transports; do
        for cell in $cells; do
            label="$transport-$cell-$workers"
            socket="$work/$label.sock"
            start_handoff_server "$workers" "$socket"
            if result="$(run_cell "$transport" "$cell" "$label" "$socket")"; then
                read -r rate per cores <<<"$result"
                printf '%s %s workers=%s: %s/s, server %s us/op, %s cores\n' \
                    "$transport" "$cell" "$workers" "$rate" "$per" "$cores"
                echo "$transport $cell $rate" >>"$work/rates-$workers"
                report 0 "$label: every operation succeeded"
            else
                report 1 "$label: every operation succeeded (see $label.out)"
            fi
            # one worker hands nothing off, and hedge keeps no series for it
            if [ "$workers" -gt 1 ]; then
                served="$(handoff_served "$workers")"
                if [ "$transport" = local ]; then
                    check_split "$label" "$workers" "$served"
                else
                    awk -v s="$served" 'BEGIN { n = split(s, v, " "); for (i = 1; i <= n; i++) if (v[i] != "0") exit 1 }'
                    report $? "$label: a reuseport listener hands nothing off ($served)"
                fi
            fi
            if ! stop_hedge; then failed=$((failed + 1)); fi
        done
    done
}

rate_of() {
    awk -v t="$2" -v c="$3" '$1 == t && $2 == c { print $3 }' "$work/rates-$1"
}

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
sha256sum "$binary" | awk '{ print "  sha256 " $1 }'
echo "connections=$connections duration=${duration}s warmup=${warmup}s workers=\"$worker_counts\" cores=$(nproc)"
echo

cores="$(nproc)"
first=""
for workers in $worker_counts; do
    measure_workers "$workers"
    # the handoff against reuseport at this count, cell by cell
    for cell in $cells; do
        local_rate="$(rate_of "$workers" local "$cell")"
        tcp_rate="$(rate_of "$workers" tcp "$cell")"
        if [ -n "$local_rate" ] && [ -n "$tcp_rate" ]; then
            awk -v l="$local_rate" -v t="$tcp_rate" -v c="$cell" -v n="$workers" \
                'BEGIN { printf "%s workers=%s: local %s/s against tcp %s/s, %.2fx\n", c, n, l, t, t ? l / t : 0 }'
        fi
    done
    if [ -z "$first" ]; then first="$workers"; continue; fi
    if [ "$workers" -gt "$cores" ]; then continue; fi
    for transport in $transports; do
        for cell in $cells; do
            base="$(rate_of "$first" "$transport" "$cell")"
            now="$(rate_of "$workers" "$transport" "$cell")"
            if [ -z "$base" ] || [ -z "$now" ]; then continue; fi
            bound="$efficiency"
            if [ "$cell" = connections ]; then bound="$accept_efficiency"; fi
            awk -v base="$base" -v now="$now" -v n="$workers" -v f="$first" -v e="$bound" \
                'BEGIN { exit !(now >= base * (n / f) * e) }'
            report $? "$transport $cell: $workers workers reach $bound of $((workers / first))x the $first-worker rate ($now/s against $base/s)"
        done
    done
done

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
