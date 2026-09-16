#!/usr/bin/env bash
# starts the live ACME stack that test/acme drives. the stack is built from Go
# sources on first use, and hooks cannot use setup-go, so a pinned toolchain is
# installed when the runner has none.
set -euo pipefail

GO_VERSION=1.26.5
GO_SHA256=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053

case "$MACH_CI_LEG" in
    x86_64-linux)
        if ! command -v go >/dev/null 2>&1; then
            root="$(pwd)/.tools/go-$GO_VERSION"
            archive="$root.tar.gz"
            mkdir -p "$root"
            curl -fsSL --max-time 300 -o "$archive" \
                "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz"
            echo "$GO_SHA256  $archive" | sha256sum -c --quiet -
            tar -xzf "$archive" -C "$root" --strip-components 1
            rm -f "$archive"
            export PATH="$root/bin:$PATH"
        fi
        go version
        test/acme/harness/start.sh
        ;;
esac
