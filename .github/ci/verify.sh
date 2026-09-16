#!/usr/bin/env bash
# concurrent-connection fairness, HTTP/3 service and the shared connection cap,
# against the release executable the standard phases built
set -euo pipefail

case "$MACH_CI_LEG" in
    x86_64-linux)
        # the served-QUIC cells wait on hedge#145. the HTTP/3 smoke, admission,
        # refusal and the shared cap are checked regardless.
        LOAD_QUIC_SERVED=0 test/load/run.sh
        ;;
esac
