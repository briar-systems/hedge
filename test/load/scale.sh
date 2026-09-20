#!/usr/bin/env bash
# idle memory per connection, measured on the real hedge binary
#
# hedge's claim after #175 is that an idle connection holds only its protocol
# state, so the process grows linearly with the connections it carries and by a
# constant small enough that 100k of them fit. This lane holds LOAD_SCALE_SMALL
# and then LOAD_SCALE_LARGE connections open and idle over each transport,
# samples the process's resident set at each step, and reports the slope in
# bytes per connection, the two halves of it, and the projection to 100k
# connections.
#
# The slope between the two counts is the regression guard: it is pinned at
# the value each transport achieved when this lane was written, and a build
# whose slope rises past the pin by more than LOAD_SCALE_TOLERANCE percent
# fails. A build that grows faster than linearly passes the pin at these
# counts only by growing slower than the pin below them, so the pin at 10k
# is also the linearity check that matters.
# The pins are the achieved figures, not the targets in #169; a build that
# regresses toward the old per-connection buffers fails here long before it
# reaches them.
#
# The resident set is what the operating system charges the process, so it
# includes hedge's records, its pool chunks and its allocator's pages, and
# excludes the kernel's socket buffers. Both ends of a step are taken from the
# same process in the same run, so a slope is a difference, not a total.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
small="${LOAD_SCALE_SMALL:-1000}"
large="${LOAD_SCALE_LARGE:-10000}"
transports="${LOAD_SCALE_TRANSPORTS:-tcp tls quic}"
tolerance="${LOAD_SCALE_TOLERANCE:-25}"
# bytes per connection achieved on dev for 0.7.0 (#214), release build on
# linux-x86_64, 1000 to 10000 connections, transparent huge pages off. the
# measured run is in test/load/README.md.
pin_tcp="${LOAD_SCALE_PIN_TCP:-13956}"
pin_tls="${LOAD_SCALE_PIN_TLS:-29591}"
pin_quic="${LOAD_SCALE_PIN_QUIC:-111857}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19110
SECURE_PORT=19111
QUIC_PORT=19112
DEPTH_CLEARTEXT_PORT=19113
DEPTH_SECURE_PORT=19114
DEPTH_QUIC_PORT=19115
PROJECTION=100000
# what hedge advertises and funds per connection by default (max_pipeline_depth)
DEPTH=2
# a connection budget that funds its fixed lanes and exactly one HTTP/3
# request: what the request lane looked like before #219 derived it
ONE_REQUEST_BYTES=262144

prepare_load
if ! resolve_h3load; then exit 1; fi

# a resident set under transparent huge pages counts 2 MiB for the first byte
# touched in each aligned region and moves as khugepaged collapses pages, so
# the figures would carry the kernel's policy rather than hedge's footprint.
# the served process runs with them disabled (PR_SET_THP_DISABLE, inherited
# across exec), which is what the figures below assume.
launcher=(python3 -c 'import ctypes, os, sys
ctypes.CDLL(None, use_errno=True).prctl(41, 1, 0, 0, 0)
os.execv(sys.argv[1], sys.argv[1:])')

# resident bytes of the served process, from the kernel's own rollup
resident() {
    awk '/^Rss:/ { printf "%d", $2 * 1024 }' "/proc/$hedge_pid/smaps_rollup"
}

# address space and mapping count: what is reserved rather than touched, and
# how many mappings hold it (the kernel caps those at vm.max_map_count)
mapped() {
    awk '/^VmSize:/ { printf "%d", $2 * 1024 }' "/proc/$hedge_pid/status"
}
mappings() {
    wc -l < "/proc/$hedge_pid/maps"
}

# one server per transport so every baseline is a process that has served
# nothing. no connection cap, a budget that admits the large count (the pool
# preallocates nothing, so the budget is a number, not memory), and keep-alive
# long enough that nothing is retired while it is being counted.
start_scale_server() {
    write_config "$work/scale.toml" \
        "max_connections_per_peer = $((large * 2))
memory_bytes = $((large * 4 * 1048576))" \
        "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" \
        "keep_alive_ms = 900000
drain_ms = 5000"
    start_hedge "$work/scale.toml"
}

# holds `count` HTTP/1.1 connections idle after one served request each
hold_http() {
    local name="$1" count="$2" tls="$3" port held
    port="$CLEARTEXT_PORT"
    if [ "$tls" = 1 ]; then port="$SECURE_PORT"; fi
    if [ "$tls" = 1 ]; then
        start_holder "$name" python3 test/load/hold.py --port "$port" \
            --connections "$count" --timeout 60 --tls
    else
        start_holder "$name" python3 test/load/hold.py --port "$port" \
            --connections "$count" --timeout 60
    fi
    held="$(held_by "$name" "${holders[${#holders[@]}-1]}")" || return 1
    test "$held" = "$count"
}

# holds `count` HTTP/3 connections idle after their handshakes, over
# test/load/h3load. handshakes are bounded to DIALING in flight: a burst past a
# few thousand loses some to their handshake timeout (#232), and this lane
# measures what an idle connection holds, not what a burst admits.
DIALING=64
hold_quic() {
    local name="$1" count="$2" held
    start_holder "$name" "$h3load" -address "127.0.0.1:$QUIC_PORT" \
        -connections "$count" -serve=false -dialing "$DIALING" \
        -connect-timeout 60s -idle-timeout 900s -hold
    held="$(held_by "$name" "${holders[${#holders[@]}-1]}")" || return 1
    test "$held" = "$count"
}

# holds `count` more connections over `transport` under holder `name`
hold_more() {
    local transport="$1" name="$2" count="$3"
    case "$transport" in
        tcp)  hold_http "$name" "$count" 0 ;;
        tls)  hold_http "$name" "$count" 1 ;;
        quic) hold_quic "$name" "$count" ;;
    esac
}

# report one transport: samples at 0, small, the midpoint and large
# connections, then after release. the first connections also bring what the
# process needs once (pool chunk classes, routing, the first table chunks), so
# the per-connection slope is taken between small and large, and the two
# halves of that span are printed beside it: a slope that keeps rising is what
# a non-linear term looks like. fails on a broken hold or a slope past the pin.
measure() {
    local transport="$1" pin="$2" r0 r1 r2 r3 r4 v3 m3
    local per_low per_high per once projection agree
    local mid=$(( (small + large) / 2 ))

    start_scale_server
    sleep 0.5
    r0="$(resident)"
    if ! hold_more "$transport" "$transport-small" "$small"; then
        report 1 "$transport: $small connections held (see $transport-small.out)"
        release_holders; stop_hedge; return 1
    fi
    sleep 0.5
    r1="$(resident)"
    if ! hold_more "$transport" "$transport-mid" $((mid - small)); then
        report 1 "$transport: $mid connections held (see $transport-mid.out)"
        release_holders; stop_hedge; return 1
    fi
    sleep 0.5
    r2="$(resident)"
    if ! hold_more "$transport" "$transport-large" $((large - mid)); then
        report 1 "$transport: $large connections held (see $transport-large.out)"
        release_holders; stop_hedge; return 1
    fi
    sleep 0.5
    r3="$(resident)"
    v3="$(mapped)"
    m3="$(mappings)"

    release_holders
    sleep 2
    r4="$(resident)"

    per_low=$(( (r2 - r1) / (mid - small) ))
    per_high=$(( (r3 - r2) / (large - mid) ))
    per=$(( (r3 - r1) / (large - small) ))
    once=$(( r1 - r0 - per * small ))
    projection=$(( r0 + once + per * PROJECTION ))
    if [ "$per_low" -gt 0 ]; then
        agree=$(( (per_high - per_low) * 100 / per_low ))
    else
        agree=0
    fi
    printf '%s: resident idle=%d at %d=%d at %d=%d at %d=%d after release=%d\n' \
        "$transport" "$r0" "$small" "$r1" "$mid" "$r2" "$large" "$r3" "$r4"
    printf '%s: at %d address space=%d MiB in %d mappings\n' \
        "$transport" "$large" $((v3 / 1048576)) "$m3"
    printf '%s: bytes/connection over %d..%d=%d over %d..%d=%d (%+d%%) over %d..%d=%d, once=%d KiB\n' \
        "$transport" "$small" "$mid" "$per_low" "$mid" "$large" "$per_high" "$agree" \
        "$small" "$large" "$per" $((once / 1024))
    printf '%s: projection at %dk=%d MiB\n' "$transport" $((PROJECTION / 1000)) $((projection / 1048576))

    if [ "$pin" -gt 0 ]; then
        test "$per" -le $(( pin + pin * tolerance / 100 ))
        report $? "$transport: $per bytes/connection is within $tolerance% of the pinned $pin"
    else
        echo "unpinned $transport: no LOAD_SCALE_PIN for this transport"
    fi
    # the recede figure is reported, not gated: the tables release their
    # trailing chunks, but what the allocator hands back to the kernel is the
    # allocator's business
    if stop_hedge; then
        report 0 "$transport: hedge stops cleanly after $large connections"
    else
        failed=$((failed + 1))
    fi
    echo
}

# DEPTH requests on one HTTP/3 connection, each throttled so they overlap if
# hedge lets them. prints one line per request: status, bytes, version, total
# time; and the connection count curl logged. this is #220: the whole path,
# advertised concurrency, handshake, the engine's own per-request draw and
# service, on a real connection under a given budget.
depth_h3() {
    local name="$1" i config
    config="$work/$name.curl"
    : >"$config"
    for i in $(seq "$DEPTH"); do
        printf 'url = "https://depth.load.test:%d/body"\noutput = "/dev/null"\n' \
            "$DEPTH_QUIC_PORT" >>"$config"
    done
    "$h3curl" --parallel --parallel-immediate --parallel-max "$DEPTH" \
        --parallel-max-host 1 --http3-only --insecure \
        --connect-to "::127.0.0.1:$DEPTH_QUIC_PORT" \
        --max-time 120 --limit-rate 8k --verbose --silent \
        --write-out '%{http_code} %{size_download} %{http_version} %{time_total}\n' \
        --config "$config" >"$work/$name.out" 2>"$work/$name.err"
    grep -c '^\* using HTTP/3' "$work/$name.err"
}

# every request served with the whole body over one connection, and either
# overlapping (the slowest finished within half again the fastest, which two
# throttled transfers only manage when they ran at the same time) or, with
# `serial`, not
depth_served() {
    local connections="$1" file="$2" shape="$3"
    awk -v want="$DEPTH" -v bytes="$BODY_BYTES" -v conns="$connections" -v shape="$shape" '
        { total++ }
        $1 == 200 && $2 == bytes && $3 == 3 {
            served++
            if ($4 > slowest) slowest = $4
            if (fastest == "" || $4 < fastest) fastest = $4
        }
        END {
            overlap = slowest < fastest * 1.5
            printf "h3-depth: connections=%d requests=%d served=%d fastest=%.1fs slowest=%.1fs %s\n",
                conns, total, served, fastest, slowest, overlap ? "overlapping" : "serial"
            if (total != want || served != want) exit 1
            if (shape == "overlap" && conns != 1) exit 1
            exit !(overlap == (shape == "overlap"))
        }' "$file"
}

measure_depth() {
    local connections
    write_config "$work/depth.toml" "max_connections_per_peer = 64" \
        "$DEPTH_CLEARTEXT_PORT" "$DEPTH_SECURE_PORT" "$DEPTH_QUIC_PORT"
    start_hedge "$work/depth.toml"
    connections="$(depth_h3 depth-default)"
    depth_served "$connections" "$work/depth-default.out" overlap
    report $? "h3: $DEPTH concurrent requests on one connection are all served at once under the default budget"
    stop_hedge || failed=$((failed + 1))

    # the counterfactual: a budget that funds one request advertises one, so
    # the same two requests are served one after the other
    write_config "$work/depth-one.toml" "max_connections_per_peer = 64
connection_memory_bytes = $ONE_REQUEST_BYTES" \
        "$DEPTH_CLEARTEXT_PORT" "$DEPTH_SECURE_PORT" "$DEPTH_QUIC_PORT"
    start_hedge "$work/depth-one.toml"
    connections="$(depth_h3 depth-one)"
    depth_served "$connections" "$work/depth-one.out" serial
    report $? "h3: under a budget that funds one request the same requests are served one after the other"
    stop_hedge || failed=$((failed + 1))
    echo
}

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "small=$small large=$large projection=$PROJECTION tolerance=$tolerance%"
echo

measure_depth

for transport in $transports; do
    case "$transport" in
        tcp)  measure tcp "$pin_tcp" ;;
        tls)  measure tls "$pin_tls" ;;
        quic) measure quic "$pin_quic" ;;
        *)    echo "unknown transport $transport"; failed=$((failed + 1)) ;;
    esac
done

echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
