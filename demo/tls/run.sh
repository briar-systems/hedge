#!/usr/bin/env bash
# generate a self-signed certificate if there is not one, then serve.
set -eu
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
cd "$repo_root"

certs="demo/tls/.certs"
mkdir -p "$certs"
if [ ! -f "$certs/demo.pem" ] || [ ! -f "$certs/demo.key" ]; then
    echo "generating a self-signed P-256 certificate for localhost" >&2
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -sha256 -days 365 -nodes \
        -keyout "$certs/demo.key" -out "$certs/demo.pem" \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
    openssl pkcs8 -topk8 -nocrypt -in "$certs/demo.key" \
        -out "$certs/demo.pk8" >/dev/null 2>&1
    mv "$certs/demo.pk8" "$certs/demo.key"
    chmod 600 "$certs/demo.key"
fi

hedge_serve demo/tls/hedge.toml
