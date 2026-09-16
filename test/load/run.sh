#!/usr/bin/env bash
# concurrent-connection fairness over the real hedge binary
#
# hedge lost requests under concurrent TLS load for as long as there has been a
# published benchmark, and nothing in the suite noticed, because every other
# test drives one connection at a time. This lane holds many connections open at
# once and asserts that service reaches all of them.
#
# The verdict is a ratio taken inside one run, never a duration, so it says the
# same thing on a fast machine and a loaded one.

set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1

binary="${HEDGE_BINARY:-out/linux-x86_64/release/bin/hedge}"
connections="${LOAD_CONNECTIONS:-256}"
target="${LOAD_TARGET:-8}"
work="$(mktemp -d)"
hedge_pid=""

CLEARTEXT_PORT=19100
SECURE_PORT=19101
BODY_BYTES=65536

cleanup() {
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

if [ ! -x "$binary" ]; then
    echo "no hedge binary at $binary"
    exit 1
fi

# the body is incompressible so that neither side can shorten the transfer, and
# large enough that serving one occupies the connection long enough for an
# unfair runtime to leave the others waiting.
mkdir -p "$work/content"
head -c "$BODY_BYTES" /dev/urandom > "$work/content/body"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -sha256 -days 1 -nodes \
    -keyout "$work/load.key" -out "$work/load.pem" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 || {
        echo "could not generate a certificate"; exit 1; }
openssl pkcs8 -topk8 -nocrypt -in "$work/load.key" -out "$work/load.pk8" \
    >/dev/null 2>&1 || { echo "could not convert the key"; exit 1; }
mv "$work/load.pk8" "$work/load.key"

# written here rather than checked in, because it carries absolute paths to the
# generated body and credentials.
cat > "$work/hedge.toml" <<EOF
[server]
name = "load"

# no global limit, so connection storage grows with the load rather than the
# run measuring a configured ceiling. the whole load comes from one peer, so
# the per-peer default would refuse it and has to be raised.
[server.limits]
max_connections_per_peer = 4096

[[listener]]
name = "cleartext"
address = "127.0.0.1:$CLEARTEXT_PORT"
protocols = ["http/1.1"]

[[listener]]
name = "secure"
address = "127.0.0.1:$SECURE_PORT"
protocols = ["http/1.1"]
tls = "load"

[tls.load]
identity = [
  { server_name = "localhost", certificate = "$work/load.pem", key = "$work/load.key" },
]
default = "localhost"

[host.site]
listener = "secure"
server_name = "localhost"

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

"$binary" "$work/hedge.toml" >"$work/hedge.log" 2>&1 &
hedge_pid=$!
ready=0
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

if stop_hedge; then
    report 0 "hedge stops cleanly after the load"
else
    failed=$((failed + 1))
fi

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
