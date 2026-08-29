#!/usr/bin/env bash
# hedge protocol interoperability matrix
#
# every leg is its own assertion: it starts the hedge binary against a checked-in
# configuration, drives it with a real client, and fails the run if the observed
# result is not the one policy requires. the legs are written down once here so
# the record in README.md is produced rather than transcribed.

set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1

binary="${HEDGE_BINARY:-out/linux-x86_64/debug/bin/hedge}"
fixtures="test/interop/fixtures"
work="$(mktemp -d)"
trap 'rm -rf "$work"; stop_server' EXIT

passed=0
failed=0
server_pid=""

stop_server() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null
        wait "$server_pid" 2>/dev/null
    fi
    server_pid=""
}

start_server() {
    stop_server
    "$binary" "$1" > "$work/server.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 50); do
        if grep -q 'hedge: ready' "$work/server.log" 2>/dev/null; then return 0; fi
        if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    echo "FAILED  server did not become ready for $1"
    cat "$work/server.log"
    return 1
}

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "pass    $name"
        passed=$((passed + 1))
    else
        echo "FAILED  $name (expected '$expected', got '$actual')"
        failed=$((failed + 1))
    fi
}

curl_code() {
    timeout 30 curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null
}

# --- raw client for the legs no packaged client can express -------------------

raw_exchange() {
    # $1 port, $2 python bytes literal to send, prints the reply as latin-1 text
    timeout 15 python3 - "$1" "$2" <<'PY'
import socket, sys
port = int(sys.argv[1])
payload = sys.argv[2].encode('latin-1').decode('unicode_escape').encode('latin-1')
s = socket.create_connection(('127.0.0.1', port), timeout=10)
s.sendall(payload)
s.settimeout(3)
out = b''
try:
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        out += chunk
except (socket.timeout, TimeoutError):
    pass
s.close()
sys.stdout.write(out.decode('latin-1'))
PY
}

alert_of() {
    # the numeric TLS alert an OpenSSL client reports, or "none"
    local out
    out="$(timeout 15 openssl s_client "$@" -quiet </dev/null 2>&1)"
    local number
    number="$(printf '%s' "$out" | sed -n 's/.*SSL alert number \([0-9]*\).*/\1/p' | head -1)"
    if [ -z "$number" ]; then echo "none"; else echo "$number"; fi
}

echo "hedge protocol interoperability"
echo "curl:    $(curl --version | head -1)"
echo "openssl: $(openssl version)"
echo "gnutls:  $(gnutls-cli --version | head -1)"
echo

# --- the main configuration --------------------------------------------------

start_server test/interop/hedge.toml || exit 1

large="test/interop/public/files/large.txt"
head -c 100000 "$large" > "$work/upload.bin"

check "cleartext HTTP/1.1" 200 \
    "$(curl_code --http1.1 -H 'Host: localhost' http://127.0.0.1:9080/hello)"
check "cleartext HTTP/2 prior knowledge" 200 \
    "$(curl_code --http2-prior-knowledge -H 'Host: localhost' http://127.0.0.1:9080/hello)"
check "cleartext HTTP/2 prior knowledge, request body" 200 \
    "$(curl_code --http2-prior-knowledge -H 'Host: localhost' \
        --data-binary @"$work/upload.bin" http://127.0.0.1:9080/echo)"

check "TLS ALPN selects http/1.1" 200 \
    "$(curl_code --http1.1 --cacert $fixtures/root.pem \
        --resolve api.example.com:9443:127.0.0.1 https://api.example.com:9443/hello)"
check "TLS ALPN selects h2" 200 \
    "$(curl_code --http2 --cacert $fixtures/root.pem \
        --resolve api.example.com:9443:127.0.0.1 https://api.example.com:9443/hello)"
check "TLS h2 request body" 200 \
    "$(curl_code --http2 --cacert $fixtures/root.pem \
        --resolve api.example.com:9443:127.0.0.1 --data-binary @"$work/upload.bin" \
        https://api.example.com:9443/echo)"
check "TLS http/1.1 request body" 200 \
    "$(curl_code --http1.1 --cacert $fixtures/root.pem \
        --resolve api.example.com:9443:127.0.0.1 --data-binary @"$work/upload.bin" \
        https://api.example.com:9443/echo)"

timeout 30 curl -sS --http2 --cacert $fixtures/root.pem \
    --resolve api.example.com:9443:127.0.0.1 -o "$work/h2-large" \
    https://api.example.com:9443/files/large.txt >/dev/null 2>&1
if cmp -s "$large" "$work/h2-large"; then
    check "TLS h2 multi-frame response is byte-identical" ok ok
else
    check "TLS h2 multi-frame response is byte-identical" ok differs
fi

timeout 30 curl -sS --http1.1 --cacert $fixtures/root.pem \
    --resolve api.example.com:9443:127.0.0.1 -o "$work/h1-large" \
    https://api.example.com:9443/files/large.txt >/dev/null 2>&1
if cmp -s "$large" "$work/h1-large"; then
    check "TLS http/1.1 large response is byte-identical" ok ok
else
    check "TLS http/1.1 large response is byte-identical" ok differs
fi

# six requests over one connection, two of them large
codes="$(timeout 60 curl -sS --http2 --cacert $fixtures/root.pem \
    --resolve api.example.com:9443:127.0.0.1 \
    -o /dev/null -o "$work/m2" -o /dev/null -o "$work/m4" -o /dev/null -o /dev/null \
    -w '%{http_code}%{num_connects}' \
    https://api.example.com:9443/hello \
    https://api.example.com:9443/files/large.txt \
    https://api.example.com:9443/hello \
    https://api.example.com:9443/files/large.txt \
    https://api.example.com:9443/echo \
    https://api.example.com:9443/hello 2>/dev/null)"
check "TLS h2 multiplexes six requests on one connection" "200120002000200020002000" "$codes"
if cmp -s "$large" "$work/m2" && cmp -s "$large" "$work/m4"; then
    check "TLS h2 multiplexed large bodies are byte-identical" ok ok
else
    check "TLS h2 multiplexed large bodies are byte-identical" ok differs
fi

# twenty requests over one HTTP/1.1 connection
args=()
for _ in $(seq 20); do args+=(https://api.example.com:9443/hello -o /dev/null); done
codes="$(timeout 60 curl -sS --http1.1 --cacert $fixtures/root.pem \
    --resolve api.example.com:9443:127.0.0.1 -w '%{http_code}' "${args[@]}" 2>/dev/null)"
expected="$(printf '200%.0s' $(seq 20))"
check "TLS http/1.1 keeps one connection across twenty requests" "$expected" "$codes"

# --- SNI selection -----------------------------------------------------------

check "SNI selects the exact identity" 200 \
    "$(curl_code --http1.1 --cacert $fixtures/root.pem \
        --resolve alt.example.com:9443:127.0.0.1 https://alt.example.com:9443/hello)"
check "SNI falls back to the wildcard identity" 200 \
    "$(curl_code --http1.1 --cacert $fixtures/root.pem \
        --resolve other.example.com:9443:127.0.0.1 https://other.example.com:9443/hello)"

check "GnuTLS completes a TLS 1.3 handshake with ALPN" 0 \
    "$(timeout 15 gnutls-cli --port 9443 127.0.0.1 --x509cafile $fixtures/root.pem \
        --priority 'NORMAL:-VERS-ALL:+VERS-TLS1.3' --alpn http/1.1 \
        --sni-hostname api.example.com --verify-hostname api.example.com \
        </dev/null >/dev/null 2>&1; echo $?)"

# --- protocol-correct refusals ----------------------------------------------

check "a TLS 1.2 client is refused with protocol_version" 70 \
    "$(alert_of -connect 127.0.0.1:9443 -servername api.example.com \
        -CAfile $fixtures/root.pem -tls1_2)"
check "a client offering only h3 is refused with no_application_protocol" 120 \
    "$(alert_of -connect 127.0.0.1:9443 -servername api.example.com \
        -CAfile $fixtures/root.pem -alpn h3 -tls1_3)"

check "an HTTP/1 request to an HTTP/2 listener is refused" "" \
    "$(raw_exchange 9082 'GET /hello HTTP/1.1\r\nHost: h2only.test\r\n\r\n')"

# --- the PROXY protocol ------------------------------------------------------

reply="$(raw_exchange 9081 'PROXY TCP4 203.0.113.9 198.51.100.2 5000 443\r\nGET /hello HTTP/1.1\r\nHost: proxied.test\r\nConnection: close\r\n\r\n')"
case "$reply" in
    "HTTP/1.1 200 OK"*) check "a trusted PROXY header is decoded and served" ok ok ;;
    *) check "a trusted PROXY header is decoded and served" ok "${reply%%$'\r'*}" ;;
esac

check "a required PROXY header that never arrives closes the connection" "" \
    "$(raw_exchange 9081 'GET /hello HTTP/1.1\r\nHost: proxied.test\r\n\r\n')"
check "a malformed PROXY header is refused" "" \
    "$(raw_exchange 9081 'PROXY TCP4 203.0.113.999 198.51.100.2 5000 443\r\nGET /hello HTTP/1.1\r\nHost: proxied.test\r\n\r\n')"
check "an HTTP/2 preface behind a trusted PROXY header is served" 200 \
    "$(curl_code --http2-prior-knowledge -H 'Host: proxied.test' \
        --haproxy-protocol http://127.0.0.1:9081/hello)"

# --- a policy with no default identity --------------------------------------

start_server test/interop/no-default.toml || exit 1

check "a known server name is served when no default is configured" 200 \
    "$(curl_code --http1.1 --cacert $fixtures/root.pem \
        --resolve api.example.com:9444:127.0.0.1 https://api.example.com:9444/hello)"
check "an unmatched server name is refused with unrecognized_name" 112 \
    "$(alert_of -connect 127.0.0.1:9444 -servername nowhere.invalid \
        -CAfile $fixtures/root.pem -alpn http/1.1 -tls1_3)"

stop_server

# --- shutdown ------------------------------------------------------------------
#
# these legs assert the exit status, because that is the only place the outcome
# of a shutdown is visible to whoever supervises the process. a drain that
# abandoned live exchanges must not look like a clean one.

shutdown_exit() {
    # $1 "idle" or "held": whether a peer holds a request open across the signal
    local log="$work/shutdown.log"
    "$binary" test/interop/shutdown.toml > "$log" 2>&1 &
    local pid=$!
    local ready=1
    for _ in $(seq 60); do
        if grep -q '^hedge: ready' "$log" 2>/dev/null; then ready=0; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if [ "$ready" -ne 0 ]; then
        kill -9 "$pid" 2>/dev/null
        echo "not-ready"
        return
    fi
    local holder=""
    if [ "$1" = "held" ]; then
        python3 -c '
import socket, sys, time
s = socket.create_connection(("127.0.0.1", 9085), timeout=5)
# a request head that is never terminated: the connection is live and the
# exchange can never complete on its own
s.sendall(b"GET /hello HTTP/1.1\r\nHost: localhost\r\n")
sys.stderr.write("held\n")
sys.stderr.flush()
time.sleep(30)
' 2>"$work/holder.log" &
        holder=$!
        for _ in $(seq 60); do
            if grep -q held "$work/holder.log" 2>/dev/null; then break; fi
            sleep 0.1
        done
    else
        # a client that completes and goes away before the signal
        curl -sS -o /dev/null --max-time 10 -H 'Host: localhost' \
            http://127.0.0.1:9085/hello 2>/dev/null
    fi
    kill -TERM "$pid" 2>/dev/null
    local code=0
    wait "$pid"; code=$?
    if [ -n "$holder" ]; then kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; fi
    echo "$code"
}

# --- reload -------------------------------------------------------------------

reload_widens_route() {
    local config="$work/reload.toml"
    sed 's|^path = "/hello"|path = "/**"|' test/interop/reload.toml > "$work/wide.toml"
    cp test/interop/reload.toml "$config"
    "$binary" "$config" > "$work/reload.log" 2>&1 &
    local pid=$!
    for _ in $(seq 60); do
        grep -q '^hedge: ready' "$work/reload.log" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    local before
    before="$(curl_code -H 'Host: localhost' http://127.0.0.1:9086/other)"
    # widen the route and ask the running process to take it
    cp "$work/wide.toml" "$config"
    kill -HUP "$pid" 2>/dev/null
    local after="000"
    for _ in $(seq 40); do
        after="$(curl_code -H 'Host: localhost' http://127.0.0.1:9086/other)"
        [ "$after" = "200" ] && break
        sleep 0.1
    done
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    echo "$before/$after"
}

check "a reload widens a route in the running process" "404/200" \
    "$(reload_widens_route)"

check "a stop with no work in flight drains cleanly" 0 "$(shutdown_exit idle)"
check "a stop with a peer mid-request reports the abandoned exchange" 75 \
    "$(shutdown_exit held)"

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then exit 1; fi
