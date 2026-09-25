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
# Each step also measures what an idle connection costs in CPU: the served
# process's CPU time over LOAD_SCALE_IDLE_SECONDS with nothing but the held
# connections (and QUIC's keep-alives, one every LOAD_SCALE_QUIC_KEEPALIVE per
# connection, over a window of one whole period), less what the server spends
# idle with none. That cost per connection per second must be flat in N: the
# large step may spend no more than the small step's per-connection cost times
# large, within LOAD_SCALE_CPU_TOLERANCE percent and 2 ms a window of noise. A
# per-event path that walks the live connections is O(N) per event and O(N^2)
# per second, and fails here. Descriptors and timer-wheel entries are counted
# at each step too: a TCP or TLS connection holds exactly one descriptor and a
# QUIC connection none, and no connection holds more than
# LOAD_SCALE_TIMERS_PER wheel entries.
#
# The connections come from several client processes, each holding at most
# LOAD_SCALE_PER_CLIENT connections from its own loopback source address
# (127.0.0.2 and up), so one address's ephemeral port range never bounds N and
# no single client's event loop is what is measured. At 100k (the manual lane)
# that is ten holders.
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
idle_seconds="${LOAD_SCALE_IDLE_SECONDS:-10}"
cpu_tolerance="${LOAD_SCALE_CPU_TOLERANCE:-50}"
quic_keepalive="${LOAD_SCALE_QUIC_KEEPALIVE:-15}"
per_client="${LOAD_SCALE_PER_CLIENT:-10000}"
timers_per="${LOAD_SCALE_TIMERS_PER:-1}"
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

# resident bytes of the served process, from the kernel's own rollup, with
# whatever of it the kernel has swapped out counted back in: under memory
# pressure a page hedge touched can leave the resident set without leaving
# hedge's footprint, and a figure that fell for that reason would read as a
# smaller per-connection cost
resident() {
    awk '/^(Rss|Swap):/ { sum += $2 } END { printf "%d", sum * 1024 }' "/proc/$hedge_pid/smaps_rollup"
}

# the part of that the kernel had swapped out, printed beside each transport
swapped() {
    awk '/^Swap:/ { printf "%d", $2 * 1024 }' "/proc/$hedge_pid/smaps_rollup"
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

# every descriptor the served process has open
descriptors() {
    find "/proc/$hedge_pid/fd" -mindepth 1 2>/dev/null | wc -l
}

# CPU time the served process's threads have run, in nanoseconds, from the
# scheduler's own accounting. /proc/<pid>/stat counts in clock ticks (10 ms),
# too coarse for what a thousand idle connections cost in a window
cpu_ns() {
    cat /proc/"$hedge_pid"/task/*/schedstat 2>/dev/null | awk '{ sum += $1 } END { printf "%d", sum }'
}

# the idle window. a QUIC connection sends a keep-alive once per period, and
# the connections of a step are dialled together, so their PINGs come in a
# burst once a period: the window is one whole period, opened one period
# after the step so every connection has reached its keep-alive cadence
window_for() {
    if [ "$1" = quic ] && [ "$quic_keepalive" -gt "$idle_seconds" ]; then
        echo "$quic_keepalive"
    else
        echo "$idle_seconds"
    fi
}

# the served process's CPU over the idle window, in nanoseconds
idle_cpu() {
    local transport="$1" window before
    window="$(window_for "$transport")"
    if [ "$transport" = quic ]; then sleep "$quic_keepalive"; fi
    before="$(cpu_ns)"
    sleep "$window"
    echo $(( $(cpu_ns) - before ))
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

# the loopback source address the next holder binds, so no two holders of
# one server share an address's ephemeral ports. each holder takes the next
next_source=2

# starts one holder of `count` HTTP/1.1 connections idle after one served
# request each, from its own source address
start_http_holder() {
    local name="$1" count="$2" tls="$3" port="$CLEARTEXT_PORT" flags=()
    local source="127.0.0.$next_source"
    next_source=$((next_source + 1))
    if [ "$tls" = 1 ]; then port="$SECURE_PORT"; flags=(--tls); fi
    start_holder "$name" python3 test/load/hold.py --port "$port" \
        --connections "$count" --timeout 60 --source "$source" "${flags[@]}"
}

# starts one holder of `count` HTTP/3 connections idle after their handshakes,
# over test/load/h3load. handshakes are bounded to DIALING in flight: a burst
# past a few thousand loses some to their handshake timeout (#232), and this
# lane measures what an idle connection holds, not what a burst admits.
DIALING=64
start_quic_holder() {
    local name="$1" count="$2" source="127.0.0.$next_source"
    next_source=$((next_source + 1))
    start_holder "$name" "$h3load" -address "127.0.0.1:$QUIC_PORT" \
        -connections "$count" -serve=false -dialing "$DIALING" \
        -connect-timeout 60s -idle-timeout 900s -keep-alive "${quic_keepalive}s" \
        -source "$source" -hold
}

# holds `count` more connections over `transport`, split across holders of at
# most per_client connections each that dial at once, and fails unless every
# one of them was held
hold_more() {
    local transport="$1" name="$2" count="$3" part=0 take held
    local left="$count"
    local names=() pids=() wants=()
    while [ "$left" -gt 0 ]; do
        take="$left"
        if [ "$take" -gt "$per_client" ]; then take="$per_client"; fi
        case "$transport" in
            tcp)  start_http_holder "$name-$part" "$take" 0 ;;
            tls)  start_http_holder "$name-$part" "$take" 1 ;;
            quic) start_quic_holder "$name-$part" "$take" ;;
        esac
        names+=("$name-$part")
        pids+=("${holders[${#holders[@]}-1]}")
        wants+=("$take")
        left=$((left - take))
        part=$((part + 1))
    done
    for part in "${!names[@]}"; do
        held="$(held_by "${names[$part]}" "${pids[$part]}")" || return 1
        test "$held" = "${wants[$part]}" || return 1
    done
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
    local c0 c1 c3 d0 d1 d3 t0 t1 t3 a1 a3 w3
    local mid=$(( (small + large) / 2 ))

    start_scale_server
    next_source=2
    sleep 0.5
    r0="$(resident)"
    s0="$(sockets)"
    d0="$(descriptors)"
    t0="$(metric hedge_timers_claimed)"
    c0="$(idle_cpu "$transport")"
    if ! hold_more "$transport" "$transport-small" "$small"; then
        report 1 "$transport: $small connections held (see $transport-small.out)"
        release_holders; stop_hedge; return 1
    fi
    sleep 0.5
    r1="$(resident)"
    d1="$(descriptors)"
    t1="$(metric hedge_timers_claimed)"
    a1="$(metric hedge_timers_armed)"
    c1="$(idle_cpu "$transport")"
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
    w3="$(swapped)"
    v3="$(mapped)"
    m3="$(mappings)"
    d3="$(descriptors)"
    t3="$(metric hedge_timers_claimed)"
    a3="$(metric hedge_timers_armed)"
    c3="$(idle_cpu "$transport")"

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
    printf '%s: at %d address space=%d MiB in %d mappings, %d KiB of the resident figure swapped out\n' \
        "$transport" "$large" $((v3 / 1048576)) "$m3" $((w3 / 1024))
    printf '%s: bytes/connection over %d..%d=%d over %d..%d=%d (%+d%%) over %d..%d=%d, once=%d KiB\n' \
        "$transport" "$small" "$mid" "$per_low" "$mid" "$large" "$per_high" "$agree" \
        "$small" "$large" "$per" $((once / 1024))
    printf '%s: projection at %dk=%d MiB\n' "$transport" $((PROJECTION / 1000)) $((projection / 1048576))

    idle_cost "$transport" "$c0" "$c1" "$c3"
    descriptors_held "$transport" "$d0" "$d1" "$d3"
    timers_held "$transport" "$t0" "$t1" "$a1" "$t3" "$a3"

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

# CPU per idle connection per second at small and large, over the server's own
# idle cost, and the assertion that it is flat in N: what large connections
# cost above idle is no more than large times the small step's per-connection
# cost, within cpu_tolerance percent and CPU_FLOOR_NS a window of noise (an
# admin scrape, a log flush)
CPU_FLOOR_NS=2000000
idle_cost() {
    local transport="$1" c0="$2" c1="$3" c3="$4"
    awk -v c0="$c0" -v c1="$c1" -v c3="$c3" -v small="$small" -v large="$large" \
        -v w="$(window_for "$transport")" -v floor="$CPU_FLOOR_NS" -v tol="$cpu_tolerance" -v t="$transport" 'BEGIN {
        idle = c0 / 1e9 / w
        low = (c1 - c0) / 1e9 / w
        high = (c3 - c0) / 1e9 / w
        printf "%s: idle CPU over %ds: %.4f cores with none, %.4f above it at %d, %.4f at %d\n",
            t, w, idle, low, small, high, large
        printf "%s: CPU per idle connection per second: %.4f us at %d, %.4f us at %d\n",
            t, low * 1e6 / small, small, high * 1e6 / large, large
        exit !(high <= (low < 0 ? 0 : low) * large / small * (1 + tol / 100) + floor / 1e9 / w)
    }'
    report $? "$transport: CPU per idle connection is flat from $small to $large within $cpu_tolerance%"
}

# a TCP or TLS connection holds its socket and nothing else, a QUIC connection
# shares the listener's
descriptors_held() {
    local transport="$1" d0="$2" d1="$3" d3="$4" want_small="$small" want_large="$large"
    if [ "$transport" = quic ]; then want_small=0; want_large=0; fi
    printf '%s: descriptors idle=%d at %d=%d at %d=%d\n' "$transport" "$d0" "$small" "$d1" "$large" "$d3"
    test $((d1 - d0)) -eq "$want_small" && test $((d3 - d0)) -eq "$want_large"
    report $? "$transport: $want_large descriptors for $large connections"
}

# the timer wheel's claimed and armed entries; a build without the gauges
# reports them missing and asserts nothing
timers_held() {
    local transport="$1" t0="$2" t1="$3" a1="$4" t3="$5" a3="$6"
    printf '%s: timer entries idle=%s at %d=%s (%s armed) at %d=%s (%s armed)\n' \
        "$transport" "$t0" "$small" "$t1" "$a1" "$large" "$t3" "$a3"
    if [ "$t0" = missing ] || [ "$t3" = missing ]; then
        echo "unmeasured $transport: this build reports no timer gauges"
        return
    fi
    test $((t3 - t0)) -le $((large * timers_per))
    report $? "$transport: at most $timers_per timer entries per connection ($((t3 - t0)) for $large)"
}

# what a fresh server keeps above its idle baseline after `count` connections
# over `transport` have come and gone, or nothing when they could not be held
# or did not leave
kept_after() {
    local transport="$1" count="$2" r0 s0 r4
    start_scale_server
    next_source=2
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
echo "small=$small large=$large projection=$PROJECTION tolerance=$tolerance% idle_window=${idle_seconds}s cpu_tolerance=$cpu_tolerance% quic_keepalive=${quic_keepalive}s per_client=$per_client"
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
