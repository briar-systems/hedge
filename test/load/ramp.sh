#!/usr/bin/env bash
# N dials at a fixed rate, with no losses
#
# #169 section 8's ramp cell: connections arrive at a steady rate the server
# can carry, and every one of them is admitted and held. Before #164 a slow
# ramp of 1100 QUIC dials lost 5 to 9% of them, because idle connections
# saturated the one pump and a handshake then waited past its Retry token's
# age. A ramp is not a burst (burst.sh): the offered rate here is below the
# server's handshake rate, so any loss is the server dropping work it had room
# for.
#
# For each transport a fresh server takes LOAD_RAMP dials at LOAD_RAMP_RATE a
# second and holds them. It passes when every dial is held, and for QUIC when
# hedge counts every one as a live connection and its admission counters show
# nothing dropped, refused or expired and the socket dropped no datagram.

set -u

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
count="${LOAD_RAMP:-1000}"
rate="${LOAD_RAMP_RATE:-200}"
transports="${LOAD_RAMP_TRANSPORTS:-tcp tls quic}"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_load EXIT

CLEARTEXT_PORT=19150
SECURE_PORT=19151
QUIC_PORT=19152
ADMIN_PORT=19153

prepare_load
if ! resolve_h3load; then exit 1; fi

# the default handshake deadline and admission, which is what a ramp has to
# pass under; only the per-peer limit is raised, since every dial comes from
# loopback, and keep-alive outlasts the hold
export HEDGE_ADMIN_TOKEN=ramp-secret
start_ramp_server() {
    write_config "$work/ramp.toml" \
        "max_connections_per_peer = $((count * 2))
memory_bytes = $((count * 4 * 1048576))" \
        "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT" \
        "keep_alive_ms = 900000" \
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
    start_hedge "$work/ramp.toml"
}

metric() {
    curl -sS -H "Authorization: Bearer $HEDGE_ADMIN_TOKEN" \
        "http://127.0.0.1:$ADMIN_PORT/metrics" \
        | awk -v name="$1" '$1 == name { print $2; found = 1 }
            END { if (!found) print "missing" }'
}

# the kernel's per-socket drop counter for the QUIC listener
socket_drops() {
    awk -v addr="$(printf '0100007F:%04X' "$QUIC_PORT")" '$2 == addr { print $NF; found = 1 }
        END { if (!found) print "missing" }' /proc/net/udp
}

ramp() {
    local transport="$1" held started elapsed drops_before
    start_ramp_server
    drops_before="$(socket_drops)"
    started="$(date +%s.%N)"
    case "$transport" in
        tcp) start_holder "$transport" python3 test/load/hold.py --port "$CLEARTEXT_PORT" \
                --connections "$count" --rate "$rate" --timeout 60 --source 127.0.0.2 ;;
        tls) start_holder "$transport" python3 test/load/hold.py --port "$SECURE_PORT" \
                --connections "$count" --rate "$rate" --timeout 60 --source 127.0.0.2 --tls ;;
        quic) start_holder "$transport" "$h3load" -address "127.0.0.1:$QUIC_PORT" \
                -connections "$count" -rate "$rate" -serve=false \
                -connect-timeout 60s -idle-timeout 900s -source 127.0.0.2 -label ramp -hold ;;
    esac
    held="$(held_by "$transport" "${holders[${#holders[@]}-1]}")"
    elapsed="$(awk -v s="$started" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1f", e - s }')"
    echo "$transport: $count dials offered at $rate/s held ${held:-none} in ${elapsed}s"
    test "${held:-0}" = "$count"
    report $? "$transport: every one of $count dials at $rate/s is held"

    if [ "$transport" = quic ]; then
        local live dropped refused expired drops_after
        live="$(metric hedge_quic_connections)"
        dropped="$(metric hedge_quic_handshakes_dropped_total)"
        refused="$(metric hedge_quic_handshakes_refused_total)"
        expired="$(metric hedge_quic_handshakes_expired_total)"
        drops_after="$(socket_drops)"
        echo "quic: live=$live dropped=$dropped refused=$refused expired=$expired socket_drops=$((drops_after - drops_before))"
        test "$live" = "$count"
        report $? "quic: hedge holds all $count as live connections ($live)"
        test "$dropped" = 0 && test "$refused" = 0 && test "$expired" = 0
        report $? "quic: no handshake was dropped, refused or expired"
        test "$drops_after" = "$drops_before"
        report $? "quic: the socket dropped no datagram ($((drops_after - drops_before)))"
    fi
    release_holders
    if ! stop_hedge; then failed=$((failed + 1)); fi
    echo
}

echo "binary $binary"
stat -c '  mtime %y  size %s' "$binary"
echo "count=$count rate=$rate/s"
echo

for transport in $transports; do
    case "$transport" in
        tcp|tls|quic) ramp "$transport" ;;
        *) echo "unknown transport $transport"; failed=$((failed + 1)) ;;
    esac
done

echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
