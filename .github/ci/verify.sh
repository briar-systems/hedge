#!/usr/bin/env bash
# concurrent-connection fairness, HTTP/3 service, the shared connection cap and
# idle memory per connection, against the release executable the standard
# phases built
set -euo pipefail

case "$MACH_CI_LEG" in
    x86_64-linux)
        # the served-QUIC cells wait on hedge#231. the HTTP/3 smoke, admission,
        # refusal and the shared cap are checked regardless.
        LOAD_QUIC_SERVED=0 test/load/run.sh
        LOAD_SCALE_SMALL=200 LOAD_SCALE_LARGE=1000 test/load/scale.sh
        ;;
esac
