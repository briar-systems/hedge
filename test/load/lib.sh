# shared by the load lanes: a real hedge binary under a generated configuration,
# holders that keep connections open, and an HTTP/3 curl.
#
# a lane sources this after setting `binary`, then calls prepare_load to make
# the work directory, the content and the credentials, and write_config to
# produce a configuration for one server.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1

work=""
hedge_pid=""
holders=()
holder_fds=()
h3curl=""
h3load=""
passed=0
failed=0

BODY_BYTES=65536
SMALL_BYTES=1024

report() {
    if [ "$1" -eq 0 ]; then
        echo "pass    $2"
        passed=$((passed + 1))
    else
        echo "FAILED  $2"
        failed=$((failed + 1))
    fi
}

cleanup_load() {
    release_holders
    stop_hedge >/dev/null 2>&1 || true
    if [ -n "$work" ]; then rm -rf "$work"; fi
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

# a lane may set `launcher` to a command that execs the binary under a policy
# of its own (the scale lane disables transparent huge pages for the process)
launcher=()
start_hedge() {
    "${launcher[@]}" "$binary" "$1" >"$work/hedge.log" 2>&1 &
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
    for _ in $(seq 3000); do
        line="$(grep -m1 '^held ' "$work/$name.out" 2>/dev/null)"
        if [ -n "$line" ]; then echo "${line#held }"; return 0; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    cat "$work/$name.out" >&2
    return 1
}

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

# fetches the body over HTTP/3 once per transfer at `rate`, each transfer
# under its own authority so curl opens a connection for it rather than
# multiplexing, and prints one line per transfer: status, bytes, version,
# connect and total time
curl_h3() {
    local port="$1" count="$2" name="$3" rate="$4"
    shift 4
    local i config="$work/$name.curl"
    : >"$config"
    for i in $(seq "$count"); do
        printf 'url = "https://%s%d.load.test:%d/body"\noutput = "/dev/null"\n' \
            "$name" "$i" "$port" >>"$config"
    done
    "$h3curl" --parallel --parallel-immediate --parallel-max "$count" \
        --http3-only --insecure --connect-to "::127.0.0.1:$port" \
        --max-time 120 --limit-rate "$rate" \
        --write-out '%{http_code} %{size_download} %{http_version} %{time_appconnect} %{time_total}\n' \
        "$@" --config "$config"
}

# the Go clients under test/load (h3load, the QUIC holder and dialler, and
# rate, the closed-loop rate client) are built into the gitignored tools
# directory with the module cache beside it, so a runner without a Go cache
# still builds them. resolve_go_tool sets `tool` to the built binary.
tool=""
resolve_go_tool() {
    local name="$1"
    tool="$root/.tools/$name"
    if [ -x "$tool" ] && [ "$tool" -nt "test/load/$name/main.go" ]; then
        return 0
    fi
    if ! command -v go >/dev/null 2>&1; then
        echo "the load lanes need go to build test/load/$name"
        return 1
    fi
    mkdir -p "$root/.tools/gopath"
    (cd "test/load/$name" && GOPATH="$root/.tools/gopath" GOFLAGS=-mod=mod \
        go build -o "$tool" .) || return 1
}

resolve_h3load() {
    resolve_go_tool h3load || return 1
    h3load="$tool"
}

# the work directory, an incompressible body so neither side can shorten a
# transfer, and an ephemeral certificate for localhost and *.load.test
prepare_load() {
    if [ ! -x "$binary" ]; then
        echo "no hedge binary at $binary"
        exit 1
    fi
    if ! resolve_h3_curl; then
        echo "the QUIC cells need a curl built with HTTP/3"
        exit 1
    fi
    work="$(mktemp -d)"
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
}

# written here rather than checked in, because it carries absolute paths to the
# generated body and credentials. the whole load comes from one peer, so the
# per-peer limit is always raised to the global one or past the load. the
# optional sixth argument is the body of a [server.timeouts] table, and the
# optional seventh is appended whole (an admin listener, telemetry).
write_config() {
    local path="$1" limits="$2" cleartext="$3" secure="$4" quic="$5" timeouts="${6:-}" extra="${7:-}"
    cat > "$path" <<EOF
[server]
name = "load"

[server.limits]
$limits

[server.timeouts]
$timeouts

[[listener]]
name = "cleartext"
address = "127.0.0.1:$cleartext"
protocols = ["http/1.1"]

[[listener]]
name = "secure"
address = "127.0.0.1:$secure"
protocols = ["http/1.1", "h2"]
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

$extra
EOF
}
