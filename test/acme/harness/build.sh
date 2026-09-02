#!/bin/sh
# build the live acme stack's binaries into the repository's gitignored .tools
# directory. safe to re-run: each binary is built only when missing.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tools="$root/.tools"
bin="$tools/gopath/bin"

GOPATH="$tools/gopath"
GOCACHE="$tools/gocache"
export GOPATH GOCACHE

if ! command -v go >/dev/null 2>&1; then
    echo "go is required to build the live acme stack" >&2
    exit 1
fi

mkdir -p "$tools"

if [ ! -x "$bin/pebble" ]; then
    echo "building pebble"
    go install github.com/letsencrypt/pebble/v2/cmd/pebble@latest
fi

if [ ! -x "$bin/pebble-challtestsrv" ]; then
    echo "building pebble-challtestsrv"
    go install github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@latest
fi

if [ ! -x "$bin/acme-proxy" ]; then
    echo "building the plain-http front end"
    (cd "$root/test/acme/harness" && go build -o "$bin/acme-proxy" .)
fi

# pebble reads its configuration and its own tls material by relative path, so
# both are copied out of the module cache next to the binaries
if [ ! -f "$tools/test/config/pebble-config.json" ]; then
    echo "installing pebble's test configuration"
    module=""
    for candidate in "$GOPATH"/pkg/mod/github.com/letsencrypt/pebble/v2@*; do
        if [ -d "$candidate/test" ]; then
            module="$candidate"
        fi
    done
    if [ -z "$module" ]; then
        echo "could not locate pebble's test data in the module cache" >&2
        exit 1
    fi
    rm -rf "$tools/test"
    cp -r "$module/test" "$tools/test"
    chmod -R u+w "$tools/test"
fi

# the staging pseudo-root is deliberately unrelated to pebble's issuer. it is
# used only to prove that an authority outside configured anchors is refused.
if [ ! -f "$tools/staging-root.pem" ]; then
    echo "fetching the staging pseudo-root"
    if ! curl -fsS --max-time 30 \
        https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem \
        -o "$tools/staging-root.pem.partial"; then
        echo "could not fetch the staging pseudo-root" >&2
        rm -f "$tools/staging-root.pem.partial"
        exit 1
    fi
    mv "$tools/staging-root.pem.partial" "$tools/staging-root.pem"
fi

echo "live acme stack built in $tools"
