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
# What a transport keeps once every connection has left is asserted for TCP
# and TLS (#235): nothing hedge holds per connection outlives it, so the
# after-release resident set is the idle baseline plus the named terms below,
# none of which grows with the peak. A second fresh server holds only the small
# count and releases it, and the two after-release figures must agree within
# the slack the peak left behind, so a term that grows with the peak fails
# even when the absolute bound has room for it.
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

# what a TCP or TLS server keeps after its connections leave, above its idle
# baseline, term by term. measured page by page on std 7.4.0, release build,
# linux-x86_64, at 1k, 10k and 20k connections (#235), where TCP kept 2,320,
# 3,928 and 3,932 KiB and TLS 2,820, 4,428 and 4,440 KiB.
#
# telemetry's log queue: log_queue_depth (256 by default) records of
# std.log.sink.QueuedRecord (8,192 bytes of record and its length). it is
# allocated at start and its pages become resident as access-log records
# first pass through it, so it is charged once whatever the peak
KEEP_LOG_QUEUE=$((256 * 8200))
# the slack a peak leaves in std's tables: one empty chunk above the lowest,
# kept on purpose so a load crossing a chunk boundary never reallocates
# (mach-std#868 for io.runtime, #874 for net.async). io.runtime's slots
# (770,048), timers (98,304) and deadline index (65,536); net.async's linux
# operations (442,368), resources (147,456) and resource map (32,768), and its
# driver slots (81,920). a peak within the tables' first chunk leaves none of it
KEEP_STD_SLACK=$((770048 + 98304 + 65536 + 442368 + 147456 + 32768 + 81920))
# one serve.Slot chunk (128 slots of connection.Connection inline): a
# connection still being retired when the sample is taken holds its chunk
KEEP_SLOT_CHUNK=1433600
# the rest, measured at 212 KiB for TCP and 712 KiB for TLS: std tables made
# at listener start and first touched under load, released pool chunks each
# class keeps up to its HIGH_WATER (memory.mach), admission's lease pages and
# the log writer's stack as far as it has been touched
KEEP_ALLOWANCE=1048576
KEEP_BOUND=$((KEEP_LOG_QUEUE + KEEP_STD_SLACK + KEEP_SLOT_CHUNK + KEEP_ALLOWANCE))
# the shape check: what large and small connections leave behind may differ
# only by the slack the larger peak left in std's tables, plus this much for
# pool chunks retained at one peak and not the other. at 1k against 10k the
# difference measured 1,589,248 to 1,593,344 bytes, and std 7.2.0's slot table
# that grew with the peak (mach-std#878) made it 1,974,272 for TLS
KEEP_SHAPE_MARGIN=131072

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19110
SECURE_PORT=19111
QUIC_PORT=19112
DEPTH_CLEARTEXT_PORT=19113
DEPTH_SECURE_PORT=19114
DEPTH_QUIC_PORT=19115
ADMIN_PORT=19116
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
# long enough that nothing is retired while it is being counted. an admin
# listener serves the metrics the release check reads.
export HEDGE_ADMIN_TOKEN=scale-secret
# every term below was measured on one worker. each worker holds tables and a
# buffer pool of its own, so these cells fix one and leave the cost of more
# to the multi-core cells
start_scale_server() {
    write_config "$work/scale.toml" \
        "max_connections_per_peer = $((large * 2))
memory_bytes = $((large * 4 * 1048576))" \
        "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" \
        "keep_alive_ms = 900000
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
max_response_bytes = 8192" 1
    start_hedge "$work/scale.toml"
}

# a metric's value from the admin listener, or `missing`
metric() {
    curl -sS -H "Authorization: Bearer $HEDGE_ADMIN_TOKEN" \
        "http://127.0.0.1:$ADMIN_PORT/metrics" \
        | awk -v name="$1" '$1 == name { print $2; found = 1 }
            END { if (!found) print "missing" }'
}

# waits up to RELEASE_WAIT seconds for hedge to hold no QUIC connection and
# prints the last count read. a QUIC connection the peer closed is kept through
# its draining period (RFC 9000 section 10.2, mach-quic's 3 s drain timeout)
# before it is released, so a sample taken on a fixed delay after release can
# measure connections still draining rather than what they left behind
RELEASE_WAIT=15
quic_released() {
    local live
    for _ in $(seq $((RELEASE_WAIT * 10))); do
        live="$(metric hedge_quic_connections)"
        if [ "$live" = 0 ]; then break; fi
        sleep 0.1
    done
    echo "$live"
    test "$live" = 0
}

# the sockets the served process has open
sockets() {
    find "/proc/$hedge_pid/fd" -lname 'socket:*' 2>/dev/null | wc -l
}

# waits up to RELEASE_WAIT seconds for hedge to have no more sockets open than
# `idle` and prints the last count read. a TCP or TLS connection whose peer
# closed is retired once hedge sees the close (TLS after its close_notify
# exchange), and its socket is closed as it goes, so the count falling back to
# the idle one is every connection having left
sockets_released() {
    local idle="$1" open
    for _ in $(seq $((RELEASE_WAIT * 10))); do
        open="$(sockets)"
        if [ "$open" -le "$idle" ]; then break; fi
        sleep 0.1
    done
    echo "$open"
    test "$open" -le "$idle"
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
    local transport="$1" pin="$2" r0 r1 r2 r3 r4 v3 m3 s0
    local per_low per_high per once projection agree
    local mid=$(( (small + large) / 2 ))

    start_scale_server
    sleep 0.5
    r0="$(resident)"
    s0="$(sockets)"
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
    if [ "$transport" = quic ]; then
        local live
        live="$(quic_released)"
        report $? "quic: hedge holds no QUIC connection after release ($live live)"
    else
        local open
        open="$(sockets_released "$s0")"
        report $? "$transport: hedge holds no connection after release ($open sockets open, $s0 at idle)"
    fi
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
    if stop_hedge; then
        report 0 "$transport: hedge stops cleanly after $large connections"
    else
        failed=$((failed + 1))
    fi
    # QUIC's after-release figure is printed, not gated: #235 names TCP and TLS
    if [ "$transport" != quic ]; then
        keeps "$transport" $((r4 - r0))
    fi
    echo
}

# what a fresh server keeps above its idle baseline after `count` connections
# over `transport` have come and gone, or nothing when they could not be held
# or did not leave
kept_after() {
    local transport="$1" count="$2" r0 s0 r4
    start_scale_server
    sleep 0.5
    r0="$(resident)"
    s0="$(sockets)"
    if ! hold_more "$transport" "$transport-shape" "$count"; then
        release_holders; stop_hedge; return 1
    fi
    release_holders
    if ! sockets_released "$s0" >/dev/null; then stop_hedge; return 1; fi
    sleep 2
    r4="$(resident)"
    stop_hedge || return 1
    echo $((r4 - r0))
}

# asserts what `transport` kept after `large` connections left: within the
# named terms of its idle baseline, and within the slack the peak left of what
# a server that only ever held `small` keeps
keeps() {
    local transport="$1" kept="$2" kept_small shape
    printf '%s: kept after release=%d bound=%d (log queue %d, std slack %d, slot chunk %d, allowance %d)\n' \
        "$transport" "$kept" "$KEEP_BOUND" "$KEEP_LOG_QUEUE" "$KEEP_STD_SLACK" \
        "$KEEP_SLOT_CHUNK" "$KEEP_ALLOWANCE"
    test "$kept" -le "$KEEP_BOUND"
    report $? "$transport: what $large connections leave behind is within the named terms of idle"

    if ! kept_small="$(kept_after "$transport" "$small")"; then
        report 1 "$transport: a fresh server holds and releases $small connections (see $transport-shape.out)"
        return
    fi
    shape=$(( kept - kept_small ))
    if [ "$shape" -lt 0 ]; then shape=$(( -shape )); fi
    printf '%s: kept after %d=%d after %d=%d, differing by %d (bound %d)\n' \
        "$transport" "$small" "$kept_small" "$large" "$kept" "$shape" \
        $(( KEEP_STD_SLACK + KEEP_SHAPE_MARGIN ))
    test "$shape" -le $(( KEEP_STD_SLACK + KEEP_SHAPE_MARGIN ))
    report $? "$transport: what connections leave behind does not grow with the peak ($small against $large)"
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
        "$DEPTH_CLEARTEXT_PORT" "$DEPTH_SECURE_PORT" "$DEPTH_QUIC_PORT" "" "" 1
    start_hedge "$work/depth.toml"
    connections="$(depth_h3 depth-default)"
    depth_served "$connections" "$work/depth-default.out" overlap
    report $? "h3: $DEPTH concurrent requests on one connection are all served at once under the default budget"
    stop_hedge || failed=$((failed + 1))

    # the counterfactual: a budget that funds one request advertises one, so
    # the same two requests are served one after the other
    write_config "$work/depth-one.toml" "max_connections_per_peer = 64
connection_memory_bytes = $ONE_REQUEST_BYTES" \
        "$DEPTH_CLEARTEXT_PORT" "$DEPTH_SECURE_PORT" "$DEPTH_QUIC_PORT" "" "" 1
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
