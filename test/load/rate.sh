#!/usr/bin/env bash
# request and handshake rates, and what each costs the server in CPU
#
# A closed-loop client (test/load/rate) keeps a fixed number of operations in
# flight for a fixed window, and the lane reads the served process's CPU time
# across the same window. Every cell reports the rate, the server's CPU per
# operation and how many cores the server used, so a rate that moved because
# the client or the box did is told apart from one that moved because hedge
# did: the CPU per operation is the server's own cost and does not depend on
# who else is on the machine.
#
# Cells, each against a fresh server:
#
#   requests over held connections: HTTP/1.1, HTTP/1.1 over TLS, HTTP/2 over
#   TLS and HTTP/3, a small body back to back on every connection
#
#   full handshakes on fresh connections: TLS and QUIC, no session resumption,
#   X25519 alone
#
# The worker-scaling cell (#169 section 8) runs every cell once per count in
# LOAD_RATE_WORKERS, setting server.workers, and asserts that each rate at N
# workers reaches LOAD_RATE_EFFICIENCY of N times the single-worker rate, up to
# the host's core count. With LOAD_RATE_WORKERS empty the server runs its
# default and nothing is asserted beyond every operation succeeding.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
connections="${LOAD_RATE_CONNECTIONS:-64}"
# requests in flight per HTTP/2 or HTTP/3 connection
streams="${LOAD_RATE_STREAMS:-1}"
# handshakes in flight at once
dialing="${LOAD_RATE_DIALING:-64}"
duration="${LOAD_RATE_DURATION:-10}"
warmup="${LOAD_RATE_WARMUP:-2}"
cells="${LOAD_RATE_CELLS:-h1 tls h2 h3 tls-handshake quic-handshake}"
worker_counts="${LOAD_RATE_WORKERS:-}"
efficiency="${LOAD_RATE_EFFICIENCY:-0.7}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19140
SECURE_PORT=19141
QUIC_PORT=19142

prepare_load
if ! resolve_go_tool rate; then exit 1; fi
rate_tool="$tool"

# the configuration for one cell's server, with server.workers set when a
# count is given. the budget and the per-peer limit admit the whole load from
# one peer, and the handshake deadline sits past the window so a handshake
# queued behind the others is measured rather than expired
start_rate_server() {
    local workers="$1"
    write_config "$work/rate.toml" \
        "max_connections_per_peer = 65536
memory_bytes = $((connections * streams * 4 * 1048576 + 1073741824))" \
        "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" \
        "handshake_ms = 60000"
    if [ -n "$workers" ]; then
        sed -i "s/^name = \"load\"$/name = \"load\"\nworkers = $workers/" "$work/rate.toml"
    fi
    start_hedge "$work/rate.toml"
}

# runs one cell and prints `rate cpu_us_per_op cores`, with the client's own
# report in <label>.out. the client reads the server's CPU time as its window
# opens and closes, so warm-up and teardown are outside it
run_cell() {
    local cell="$1" label="$2" protocol mode address inflight
    case "$cell" in
        h1)  protocol=h1;  mode=requests;   address="127.0.0.1:$CLEARTEXT_PORT" ;;
        tls) protocol=tls; mode=requests;   address="127.0.0.1:$SECURE_PORT" ;;
        h2)  protocol=h2;  mode=requests;   address="127.0.0.1:$SECURE_PORT" ;;
        h3)  protocol=h3;  mode=requests;   address="127.0.0.1:$QUIC_PORT" ;;
        tls-handshake)  protocol=tls; mode=handshakes; address="127.0.0.1:$SECURE_PORT" ;;
        quic-handshake) protocol=h3;  mode=handshakes; address="127.0.0.1:$QUIC_PORT" ;;
        *) echo "unknown cell $cell" >&2; return 2 ;;
    esac
    inflight="$connections"
    if [ "$mode" = handshakes ]; then inflight="$dialing"; fi

    local out="$work/$label.out" rate cpu
    if ! "$rate_tool" -address "$address" -protocol "$protocol" -mode "$mode" \
        -connections "$inflight" -streams "$streams" -path /small \
        -body-bytes "$SMALL_BYTES" -duration "${duration}s" -warmup "${warmup}s" \
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

# every cell against a fresh server, so no cell's connections or pool growth
# are carried into the next. prints `cell rate` lines into rates-<workers>
measure_workers() {
    local workers="$1" tag="${1:-default}" cell result rate per cores
    : >"$work/rates-$tag"
    for cell in $cells; do
        start_rate_server "$workers"
        if result="$(run_cell "$cell" "$cell-$tag")"; then
            read -r rate per cores <<<"$result"
            printf '%s workers=%s: %s/s, server %s us/op, %s cores\n' \
                "$cell" "$tag" "$rate" "$per" "$cores"
            echo "$cell $rate" >>"$work/rates-$tag"
            report 0 "$cell: every operation succeeded with $tag workers"
        else
            report 1 "$cell: every operation succeeded with $tag workers (see $cell-$tag.out)"
        fi
        if ! stop_hedge; then failed=$((failed + 1)); fi
    done
}

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
sha256sum "$binary" | awk '{ print "  sha256 " $1 }'
echo "connections=$connections streams=$streams dialing=$dialing duration=${duration}s warmup=${warmup}s cores=$(nproc)"
echo

if [ -z "$worker_counts" ]; then
    measure_workers ""
else
    cores="$(nproc)"
    first=""
    for workers in $worker_counts; do
        measure_workers "$workers"
        if [ -z "$first" ]; then first="$workers"; continue; fi
        if [ "$workers" -gt "$cores" ]; then continue; fi
        # each cell's rate at this count against the first count's, scaled
        for cell in $cells; do
            base="$(awk -v c="$cell" '$1 == c { print $2 }' "$work/rates-$first")"
            now="$(awk -v c="$cell" '$1 == c { print $2 }' "$work/rates-$workers")"
            if [ -z "$base" ] || [ -z "$now" ]; then continue; fi
            awk -v base="$base" -v now="$now" -v n="$workers" -v f="$first" -v e="$efficiency" \
                'BEGIN { exit !(now >= base * (n / f) * e) }'
            report $? "$cell: $workers workers reach $efficiency of $((workers / first))x the $first-worker rate ($now/s against $base/s)"
        done
    done
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
