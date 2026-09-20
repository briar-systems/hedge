#!/usr/bin/env bash
# concurrent-connection fairness, HTTP/3 service, the shared connection cap,
# idle memory per connection and a handshake burst, against the release
# executable the standard phases built
set -euo pipefail

case "$MACH_CI_LEG" in
    x86_64-linux)
        test/load/run.sh
        LOAD_SCALE_SMALL=200 LOAD_SCALE_LARGE=1000 test/load/scale.sh
        # a burst past the runner's crypto rate: two cores and no AES-NI
        # guarantee, so the burst is kept where a run finishes inside a minute
        LOAD_BURST_WARM=100 LOAD_BURST=1000 test/load/burst.sh
        ;;
esac
