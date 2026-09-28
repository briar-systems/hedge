#!/usr/bin/env bash
# concurrent-connection fairness, HTTP/3 service, the shared connection cap,
# idle memory and CPU per connection, a handshake burst, a ramp, a sustained
# keep-alive rate, churn, request and handshake rates, the handoff and QUIC
# migration,
# against the release executable the standard phases built
set -euo pipefail

case "$MACH_CI_LEG" in
    x86_64-linux)
        test/load/run.sh
        LOAD_SCALE_SMALL=200 LOAD_SCALE_LARGE=1000 test/load/scale.sh
        # a burst past the runner's crypto rate: two cores and no AES-NI
        # guarantee, so the burst is kept where a run finishes inside a minute
        LOAD_BURST_WARM=100 LOAD_BURST=1000 test/load/burst.sh
        # the scale harness's 1k cells (#176): a ramp, a minute of churn, the
        # request and handshake rates, and QUIC connections surviving a rebind
        LOAD_RAMP=1000 test/load/ramp.sh
        # a sustained keep-alive rate with no datagram dropped (#274), at a
        # rate the runner's two cores carry beside the client
        LOAD_KEEPALIVE=2000 test/load/keepalive.sh
        # the client shares the runner's two cores with the server, which moves
        # CPU per connection more than a quiet box does over a minute
        LOAD_CHURN_SECONDS=60 LOAD_CHURN_SAMPLE=5 LOAD_CHURN_CPU_TOLERANCE=50 test/load/churn.sh
        LOAD_RATE_DURATION=5 LOAD_RATE_WARMUP=1 test/load/rate.sh
        # the handoff over a local listener against reuseport TCP (#299). four
        # workers is past the runner's cores, so the split is asserted there
        # and the scaling is left to a measured run
        LOAD_HANDOFF_WORKERS="1 4" LOAD_HANDOFF_DURATION=5 LOAD_HANDOFF_WARMUP=1 test/load/handoff.sh
        test/load/migrate.sh
        ;;
esac
