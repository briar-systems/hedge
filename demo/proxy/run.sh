#!/usr/bin/env bash
# start a tiny upstream, then hedge in front of it. stopping this script stops
# both.
set -eu
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
cd "$repo_root"

binary="$(hedge_binary)"

python3 -m http.server 8082 --bind 127.0.0.1 \
    --directory demo/proxy/origin >/dev/null 2>&1 &
upstream=$!
trap 'kill "$upstream" 2>/dev/null; wait "$upstream" 2>/dev/null' EXIT

for _ in $(seq 50); do
    curl -sf -o /dev/null http://127.0.0.1:8082/ && break
    sleep 0.1
done
echo "upstream ready on 127.0.0.1:8082" >&2

echo "hedge demo/proxy/hedge.toml" >&2
"$binary" demo/proxy/hedge.toml
