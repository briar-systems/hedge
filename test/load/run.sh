#!/usr/bin/env bash
# concurrent-connection fairness and growth over the real hedge binary
#
# hedge lost requests under concurrent TLS load for as long as there has been a
# published benchmark, and nothing in the suite noticed, because every other
# test drives one connection at a time. This lane holds many connections open at
# once and asserts that service reaches all of them, over TCP and over QUIC, and
# that a configured connection cap binds both transports at the same number.
#
# The verdict is a ratio taken inside one run, never a duration, so it says the
# same thing on a fast machine and a loaded one.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
connections="${LOAD_CONNECTIONS:-256}"
# the target is large enough that the ratio outlasts the ramp: workers take
# their first connections at different moments, and over a handful of
# requests that alone spreads the counts (#173). a starved connection still
# stands out at any target
target="${LOAD_TARGET:-40}"
# past the 1024 QUIC connections a server with no configured limit used to be
# capped at, so this cell fails on any build that still preallocates
quic_connections="${LOAD_QUIC_CONNECTIONS:-1100}"
# every transfer has to outlast the dial burst, or the cell cannot show that all
# of them were held open at once. the burst is bounded by the handshake rate,
# and until #174 one worker completes every QUIC handshake, so under load it can
# run past 20 s. a 64 KiB body at 1 KiB/s takes 64 s, which outlasts any burst
# the connect timeout allows (#301)
quic_connect_timeout=60
quic_rate="${LOAD_QUIC_RATE:-1k}"
# 0 skips every assertion that HTTP/3 transfers were served, for a box whose
# crypto rate cannot carry the burst; admission and refusal are still checked.
quic_served="${LOAD_QUIC_SERVED:-1}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19100
SECURE_PORT=19101
QUIC_PORT=19102
CAPPED_CLEARTEXT_PORT=19103
CAPPED_SECURE_PORT=19104
CAPPED_QUIC_PORT=19105
# the capped server admits this many connections across every transport
CAP=48
CAP_TCP=32
# the capped cell only needs its admitted transfers open while TCP is tried again
CAPPED_QUIC_RATE=4k

prepare_load

# no connection limit, so connection storage grows with the load rather than
# the run measuring a configured ceiling. the pool defaults to 256 connections'
# worth without one, so it is sized for the burst outright, and the handshake
# and request deadlines are lifted past the run: this cell measures service
# under concurrency, the burst lane measures the deadline
write_config "$work/hedge.toml" \
    "max_connections_per_peer = 4096
memory_bytes = $((quic_connections * 4 * 1048576))" \
    "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" \
    "handshake_ms = 60000
request_ms = 120000"
start_hedge "$work/hedge.toml"

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "connections=$connections target=$target body=${BODY_BYTES}B"
echo

# the cleartext cell is the control. it shares the load generator, the box and
# the body with the TLS cell, so a cleartext failure means the run itself is not
# trustworthy rather than that hedge is unfair.
python3 test/load/fairness.py \
    --host localhost --port "$CLEARTEXT_PORT" --path /body \
    --connections "$connections" --target "$target" --body-bytes "$BODY_BYTES" \
    --label "cleartext"
report $? "every cleartext connection is served under concurrent load"

python3 test/load/fairness.py \
    --host localhost --port "$SECURE_PORT" --path /body --tls \
    --connections "$connections" --target "$target" --body-bytes "$BODY_BYTES" \
    --label "tls"
report $? "every TLS connection is served under concurrent load"

# a small body over HTTP/3, one connection at a time. this is what keeps a
# change that stops HTTP/3 being served at all from merging, as #143 did
smoke=0
for i in 1 2 3 4 5; do
    fetched="$("$h3curl" --http3-only --insecure --silent --max-time 10 \
        --connect-to "::127.0.0.1:$QUIC_PORT" --output /dev/null \
        --write-out '%{http_code} %{size_download} %{http_version}' \
        "https://smoke$i.load.test:$QUIC_PORT/small")"
    if [ "$fetched" = "200 $SMALL_BYTES 3" ]; then smoke=$((smoke + 1)); fi
done
test "$smoke" = 5
report $? "a small body is served over HTTP/3 ($smoke of 5)"

if [ "$quic_served" = 1 ]; then
    # no limit is configured, so every one of these has to be admitted, held open
    # and served at once. the rate limit keeps every transfer running until after
    # the last one has connected, and that overlap is checked from curl's own
    # timings rather than assumed.
    curl_h3 "$QUIC_PORT" "$quic_connections" open "$quic_rate" --silent \
        --connect-timeout "$quic_connect_timeout" \
        >"$work/open.out" 2>"$work/open.err"
    awk -v want="$quic_connections" -v bytes="$BODY_BYTES" '
        { total++ }
        $1 == 200 && $2 == bytes && $3 == 3 {
            served++
            if ($4 > connected) connected = $4
            if (finished == "" || $5 < finished) finished = $5
        }
        END {
            printf "h3: connections=%d served=%d last_connected=%.1fs first_finished=%.1fs\n",
                want, served, connected, finished
            exit !(total == want && served == want && connected < finished)
        }' "$work/open.out"
    report $? "every one of $quic_connections concurrent QUIC connections is served with no configured limit"
else
    echo "skipped every one of $quic_connections concurrent QUIC connections is served (LOAD_QUIC_SERVED=0)"
fi

if stop_hedge; then
    report 0 "hedge stops cleanly after the load"
else
    failed=$((failed + 1))
fi

# a configured cap is one process-wide number, whichever transport a
# connection arrives on. TCP takes part of it, QUIC must be admitted to exactly
# the rest, and then TCP must be refused because QUIC holds the remainder.
# exactly is one worker's promise: across workers the cap is never exceeded,
# but a worker may refuse while another holds allowance it is not using, up to
# the worker count times a batch, so this cell runs one
echo
write_config "$work/capped.toml" \
    "max_connections = $CAP
max_connections_per_peer = $CAP" \
    "$CAPPED_CLEARTEXT_PORT" "$CAPPED_SECURE_PORT" "$CAPPED_QUIC_PORT" "" "" 1
start_hedge "$work/capped.toml"

start_holder tcp python3 test/load/hold.py --port "$CAPPED_CLEARTEXT_PORT" \
    --connections "$CAP_TCP"
held="$(held_by tcp "${holders[0]}")"
test "$held" = "$CAP_TCP"
report $? "a cap of $CAP holds $CAP_TCP TCP connections (held ${held:-none})"

# the QUIC transfers are slowed so the admitted ones are still open when TCP is
# tried again. a refused QUIC connection is never answered, so it fails its
# connect timeout, and curl logs one `using HTTP/3` per connection admitted.
quic_room=$((CAP - CAP_TCP))
curl_h3 "$CAPPED_QUIC_PORT" "$CAP_TCP" capped "$CAPPED_QUIC_RATE" --verbose --silent \
    --connect-timeout 15 >"$work/capped.out" 2>"$work/capped.err" &
capped_pid=$!
admitted=0
for _ in $(seq 300); do
    admitted="$(grep -c '^\* using HTTP/3' "$work/capped.err" 2>/dev/null)"
    if [ "${admitted:-0}" -ge "$quic_room" ]; then break; fi
    if ! kill -0 "$capped_pid" 2>/dev/null; then break; fi
    sleep 0.1
done

start_holder refused python3 test/load/hold.py --port "$CAPPED_CLEARTEXT_PORT" \
    --connections 8 --timeout 5
held="$(held_by refused "${holders[1]}")"
test "$held" = "0"
report $? "TCP is refused once QUIC holds the rest of the cap (held ${held:-none})"

wait "$capped_pid"
# admission is counted from the handshakes curl completed, not from the
# transfers that finished, so a transfer that stalls after it was admitted
# still counts as admitted rather than as refused
admitted="$(grep -c '^\* using HTTP/3' "$work/capped.err")"
echo "h3-capped: tried=$CAP_TCP admitted=$admitted"
test "$admitted" = "$quic_room"
report $? "QUIC is admitted to exactly the $quic_room the TCP connections leave and refused past it"
if [ "$quic_served" = 1 ]; then
    awk -v want="$quic_room" -v bytes="$BODY_BYTES" '
        $1 == 200 && $2 == bytes && $3 == 3 { served++ }
        END { printf "h3-capped: served=%d\n", served; exit !(served == want) }
    ' "$work/capped.out"
    report $? "every admitted QUIC connection under the cap is served"
fi

release_holders
if stop_hedge; then
    report 0 "the capped hedge stops cleanly after the load"
else
    failed=$((failed + 1))
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
