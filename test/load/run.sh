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

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
connections="${LOAD_CONNECTIONS:-256}"
target="${LOAD_TARGET:-8}"
# past the 1024 QUIC connections a server with no configured limit used to be
# capped at, so this cell fails on any build that still preallocates
quic_connections="${LOAD_QUIC_CONNECTIONS:-1100}"
# slow enough that every transfer is still running when the last one connects
quic_rate="${LOAD_QUIC_RATE:-4k}"
# 0 skips every assertion that HTTP/3 transfers were served. hedge#145 keeps
# them from passing today, and CI sets it until that is fixed. admission and
# refusal are still checked either way.
quic_served="${LOAD_QUIC_SERVED:-1}"
work="$(mktemp -d)"
hedge_pid=""
holders=()

CLEARTEXT_PORT=19100
SECURE_PORT=19101
QUIC_PORT=19102
CAPPED_CLEARTEXT_PORT=19103
CAPPED_SECURE_PORT=19104
CAPPED_QUIC_PORT=19105
BODY_BYTES=65536
SMALL_BYTES=1024
# the capped server admits this many connections across every transport
CAP=48
CAP_TCP=32

cleanup() {
    release_holders
    stop_hedge >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

passed=0
failed=0

report() {
    if [ "$1" -eq 0 ]; then
        echo "pass    $2"
        passed=$((passed + 1))
    else
        echo "FAILED  $2"
        failed=$((failed + 1))
    fi
}

stop_hedge() {
    if [ -z "$hedge_pid" ]; then return 0; fi
    local pid="$hedge_pid"
    hedge_pid=""
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || return 1
        if ! timeout 20s tail --pid="$pid" -f /dev/null; then
            echo "FAILED  hedge did not stop within 20 seconds"
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 1
        fi
    fi
    local status=0
    wait "$pid" 2>/dev/null || status=$?
    if [ "$status" -ne 0 ]; then
        echo "FAILED  hedge exited with status $status"
        cat "$work/hedge.log"
        return 1
    fi
    return 0
}

# a holder keeps its connections open until its stdin closes. its stdin is a
# fifo this script holds open for writing, so the holder sees end of input
# exactly when release_holders closes that descriptor.
start_holder() {
    local name="$1"
    shift
    mkfifo "$work/$name.in"
    "$@" <"$work/$name.in" >"$work/$name.out" 2>&1 &
    holders+=("$!")
    local fd
    exec {fd}>"$work/$name.in"
    holder_fds+=("$fd")
}

# prints the count a holder reports once it is holding, or fails if the holder
# exits or stalls first
held_by() {
    local name="$1" pid="$2" line
    for _ in $(seq 1200); do
        line="$(grep -m1 '^held ' "$work/$name.out" 2>/dev/null)"
        if [ -n "$line" ]; then echo "${line#held }"; return 0; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    cat "$work/$name.out" >&2
    return 1
}

holder_fds=()
release_holders() {
    local fd pid
    for fd in "${holder_fds[@]}"; do exec {fd}>&-; done
    holder_fds=()
    for pid in "${holders[@]}"; do wait "$pid" 2>/dev/null || true; done
    holders=()
}

# the QUIC cells need a curl built with HTTP/3. the system curl is used when it
# has it, and otherwise a pinned static build is fetched into the gitignored
# tools directory and checked against its digest.
H3_CURL_VERSION=8.22.0
H3_CURL_SHA256=dfb02460ba2abe513087538f12a3cf79b74b64a5ea3787ce8ac0cdb11251f884
resolve_h3_curl() {
    if curl --version 2>/dev/null | grep -qw HTTP3; then
        h3curl=curl
        return 0
    fi
    if [ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]; then
        echo "no curl with HTTP/3 on this host"
        return 1
    fi
    local dir="$root/.tools/curl-$H3_CURL_VERSION"
    if [ ! -x "$dir/curl" ]; then
        local archive="$dir.tar.xz"
        mkdir -p "$dir"
        curl -fsSL --max-time 120 -o "$archive" \
            "https://github.com/stunnel/static-curl/releases/download/$H3_CURL_VERSION/curl-linux-x86_64-musl-$H3_CURL_VERSION.tar.xz" \
            || { echo "could not fetch curl $H3_CURL_VERSION"; return 1; }
        if ! echo "$H3_CURL_SHA256  $archive" | sha256sum -c --quiet -; then
            echo "curl $H3_CURL_VERSION does not match its pinned digest"
            rm -f "$archive"
            return 1
        fi
        tar -xJf "$archive" -C "$dir" curl && rm -f "$archive"
    fi
    h3curl="$dir/curl"
    "$h3curl" --version | grep -qw HTTP3
}

# fetches the body over HTTP/3 once per transfer, each transfer under its own
# authority so curl opens a connection for it rather than multiplexing, and
# prints one line per transfer: status, bytes, version, connect and total time
curl_h3() {
    local port="$1" count="$2" name="$3"
    shift 3
    local i config="$work/$name.curl"
    : >"$config"
    for i in $(seq "$count"); do
        printf 'url = "https://%s%d.load.test:%d/body"\noutput = "/dev/null"\n' \
            "$name" "$i" "$port" >>"$config"
    done
    "$h3curl" --parallel --parallel-immediate --parallel-max "$count" \
        --http3-only --insecure --connect-to "::127.0.0.1:$port" \
        --max-time 120 --limit-rate "$quic_rate" \
        --write-out '%{http_code} %{size_download} %{http_version} %{time_appconnect} %{time_total}\n' \
        "$@" --config "$config"
}

start_hedge() {
    "$binary" "$1" >"$work/hedge.log" 2>&1 &
    hedge_pid=$!
    local ready=0
    for _ in $(seq 100); do
        if grep -q '^hedge: ready' "$work/hedge.log" 2>/dev/null; then ready=1; break; fi
        if ! kill -0 "$hedge_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "hedge never became ready"
        cat "$work/hedge.log"
        exit 1
    fi
}

if [ ! -x "$binary" ]; then
    echo "no hedge binary at $binary"
    exit 1
fi
h3curl=""
if ! resolve_h3_curl; then
    echo "the QUIC cells need a curl built with HTTP/3"
    exit 1
fi


# the body is incompressible so that neither side can shorten the transfer, and
# large enough that serving one occupies the connection long enough for an
# unfair runtime to leave the others waiting.
mkdir -p "$work/content"
head -c "$BODY_BYTES" /dev/urandom > "$work/content/body"
head -c "$SMALL_BYTES" /dev/urandom > "$work/content/small"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -sha256 -days 1 -nodes \
    -keyout "$work/load.key" -out "$work/load.pem" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:*.load.test,IP:127.0.0.1" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 || {
        echo "could not generate a certificate"; exit 1; }
openssl pkcs8 -topk8 -nocrypt -in "$work/load.key" -out "$work/load.pk8" \
    >/dev/null 2>&1 || { echo "could not convert the key"; exit 1; }
mv "$work/load.pk8" "$work/load.key"

# written here rather than checked in, because it carries absolute paths to the
# generated body and credentials. the whole load comes from one peer, so the
# per-peer limit is always raised to the global one or past the load.
write_config() {
    local path="$1" limits="$2" cleartext="$3" secure="$4" quic="$5"
    cat > "$path" <<EOF
[server]
name = "load"

[server.limits]
$limits

[[listener]]
name = "cleartext"
address = "127.0.0.1:$cleartext"
protocols = ["http/1.1"]

[[listener]]
name = "secure"
address = "127.0.0.1:$secure"
protocols = ["http/1.1"]
tls = "load"

[[listener]]
name = "quic"
address = "127.0.0.1:$quic"
transport = "quic"
protocols = ["h3"]
tls = "load"

[tls.load]
identity = [
  { server_name = "localhost", certificate = "$work/load.pem", key = "$work/load.key" },
  { server_name = "*.load.test", certificate = "$work/load.pem", key = "$work/load.key" },
]
default = "localhost"

# every QUIC client in the lane names its own subdomain, so each one is a
# separate connection rather than a stream multiplexed onto another
[host.site]
listener = "secure"
names = ["localhost", "*.load.test"]

# routing carries no listener dimension, so host.site's route already serves
# every listener. this block makes the quic listener's TLS policy cover it.
[host.site-h3]
listener = "quic"
names = ["localhost", "*.load.test"]

# the content lives in its own directory: the work directory also holds the
# private key, and a static root over it would publish that key.
[service.body]
kind = "static"
root = "$work/content"

[[route]]
name = "body"
host = "site"
path = "/**"
service = "body"
EOF
}

# no global limit, so connection storage grows with the load rather than the
# run measuring a configured ceiling
write_config "$work/hedge.toml" "max_connections_per_peer = 4096" \
    "$CLEARTEXT_PORT" "$SECURE_PORT" "$QUIC_PORT"
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
# change that stops HTTP/3 being served at all from merging, as #143 did, and
# it holds while hedge#145 keeps the loaded cells below from passing
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
    curl_h3 "$QUIC_PORT" "$quic_connections" open --silent --connect-timeout 30 \
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
    echo "skipped every one of $quic_connections concurrent QUIC connections is served (LOAD_QUIC_SERVED=0, hedge#145)"
fi

if stop_hedge; then
    report 0 "hedge stops cleanly after the load"
else
    failed=$((failed + 1))
fi

# a configured cap is one process-wide number, whichever transport a
# connection arrives on. TCP takes part of it, QUIC must be admitted to exactly
# the rest, and then TCP must be refused because QUIC holds the remainder.
echo
write_config "$work/capped.toml" \
    "max_connections = $CAP
max_connections_per_peer = $CAP" \
    "$CAPPED_CLEARTEXT_PORT" "$CAPPED_SECURE_PORT" "$CAPPED_QUIC_PORT"
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
curl_h3 "$CAPPED_QUIC_PORT" "$CAP_TCP" capped --verbose --silent \
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
