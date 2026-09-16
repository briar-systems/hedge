#!/usr/bin/env bash
# stops the live ACME stack so no listener outlives the leg
set -euo pipefail

case "$MACH_CI_LEG" in
    x86_64-linux) test/acme/harness/start.sh.stop ;;
esac
